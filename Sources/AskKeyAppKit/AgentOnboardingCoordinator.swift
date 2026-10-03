import Foundation
import Observation

@Observable
@MainActor
final class AgentOnboardingCoordinator {
    private(set) var sessions: [AgentClient: AgentClientOnboardingSession]
    var expandedClient: AgentClient?
    var operations: AgentOnboardingOperations
    var writeSettledHandler: (() -> Void)?

    private let clock: () -> Date
    private var cancellations: [AgentClient: AgentCheckCancellation] = [:]
    private var authenticationBusy = false

    init(
        operations: AgentOnboardingOperations = .inactive,
        clock: @escaping () -> Date = Date.init,
        initialSessions: [AgentClient: AgentClientOnboardingSession] = [:]
    ) {
        self.operations = operations
        self.clock = clock
        var sessions: [AgentClient: AgentClientOnboardingSession] = [:]
        for client in AgentClient.allCases {
            sessions[client] = initialSessions[client] ?? .idle
        }
        self.sessions = sessions
    }

    func session(for client: AgentClient) -> AgentClientOnboardingSession {
        sessions[client] ?? .idle
    }

    var hasInFlightWrite: Bool {
        sessions.values.contains { $0.attempt.phase.isWriteInFlight }
    }

    func appear() {
        // Memory-only: show lastKnownResult already held. No CLI, network, or keychain.
    }

    func disappear() {
        for client in AgentClient.allCases {
            cancelCheck(client)
        }
    }

    func explain(_ client: AgentClient) {
        expandedClient = client
        var session = session(for: client)
        if session.attempt.phase == .idle {
            session.attempt.phase = .explanation
            sessions[client] = session
        }
    }

    func collapse() {
        if let client = expandedClient {
            cancelCheck(client)
        }
        expandedClient = nil
    }

    func startCheck(_ client: AgentClient) async {
        var session = session(for: client)
        if session.attempt.phase.isInFlight { return }
        if session.attempt.changeStatus == .restoreFailed {
            // Ordinary write retry is blocked; a readonly check is still allowed.
        }
        let operationID = UUID()
        let cancellation = AgentCheckCancellation()
        session.operationID = operationID
        session.attempt.phase = .checking
        session.attempt.failure = nil
        session.attempt.message = ""
        sessions[client] = session
        cancellations[client] = cancellation
        expandedClient = client

        do {
            let report = try await operations.check(client, cancellation)
            guard sessions[client]?.operationID == operationID else { return }
            applyCheckReport(client, report, cancelled: cancellation.isCancelled)
        } catch {
            guard sessions[client]?.operationID == operationID else { return }
            applyCheckFailure(client, error, cancelled: cancellation.isCancelled)
        }
    }

    func cancelCheck(_ client: AgentClient) {
        let session = session(for: client)
        guard session.attempt.phase.isReadonlyInFlight else { return }
        cancellations[client]?.cancel()
        if recoveryLock(session.attempt.changeStatus) != nil {
            abandonOperation(for: client, returningTo: .recoveryRequired)
        } else {
            abandonOperation(for: client, returningTo: session.plan == nil ? .explanation : .readyToConfirm)
        }
    }

    func abandonOperation(for client: AgentClient, returningTo phase: AgentOnboardingPhase = .explanation) {
        cancellations[client]?.cancel()
        var session = session(for: client)
        let wasAuthenticating = session.attempt.phase == .authenticating
        session.operationID = UUID()
        if session.attempt.phase.isReadonlyInFlight || session.attempt.phase == .authenticating {
            if let locked = recoveryLock(session.attempt.changeStatus),
               session.attempt.phase.isReadonlyInFlight {
                session.attempt.phase = .recoveryRequired
                session.attempt.failure = recoveryFailure(locked)
                session.attempt.message = ""
            } else {
                session.attempt.phase = phase
                session.attempt.failure = nil
                session.attempt.message = ""
            }
        }
        sessions[client] = session
        if wasAuthenticating {
            notifyWriteSettledIfNeeded()
        }
    }

    func notifyWriteSettledIfNeeded() {
        guard !hasInFlightWrite else { return }
        let handler = writeSettledHandler
        writeSettledHandler = nil
        handler?()
    }

    func confirm(_ client: AgentClient) async {
        var session = session(for: client)
        guard let plan = session.plan else { return }
        guard session.attempt.phase == .readyToConfirm || session.attempt.phase == .needsAction else { return }
        guard session.attempt.changeStatus != .restoreFailed else { return }
        if session.attempt.phase.isInFlight { return }

        let operationID = UUID()
        session.operationID = operationID
        session.attempt.phase = .authenticating
        session.attempt.failure = nil
        sessions[client] = session

        if authenticationBusy {
            session.attempt.phase = .readyToConfirm
            sessions[client] = session
            notifyWriteSettledIfNeeded()
            return
        }
        authenticationBusy = true
        let auth = await operations.authenticate()
        authenticationBusy = false
        guard sessions[client]?.operationID == operationID else {
            notifyWriteSettledIfNeeded()
            return
        }

        switch auth {
        case .cancelled:
            session.attempt.phase = .readyToConfirm
            session.attempt.failure = nil
            sessions[client] = session
            notifyWriteSettledIfNeeded()
            return
        case .failed:
            session.attempt.phase = .needsAction
            session.attempt.failure = .permissionDenied
            sessions[client] = session
            notifyWriteSettledIfNeeded()
            return
        case .confirmed:
            break
        }

        guard await operations.revalidateWriteSession() else {
            guard sessions[client]?.operationID == operationID else {
                notifyWriteSettledIfNeeded()
                return
            }
            session.attempt.phase = .needsAction
            session.attempt.failure = .permissionDenied
            sessions[client] = session
            notifyWriteSettledIfNeeded()
            return
        }
        guard sessions[client]?.operationID == operationID else {
            notifyWriteSettledIfNeeded()
            return
        }

        session.attempt.phase = .applying
        sessions[client] = session
        do {
            let report = try await operations.apply(client, plan, AgentCheckCancellation())
            guard sessions[client]?.operationID == operationID else {
                notifyWriteSettledIfNeeded()
                return
            }
            applyApplyReport(client, report)
        } catch {
            guard sessions[client]?.operationID == operationID else {
                notifyWriteSettledIfNeeded()
                return
            }
            applyApplyFailure(client, error)
        }
        notifyWriteSettledIfNeeded()
    }

    func cancelAuthentication(_ client: AgentClient) {
        let session = session(for: client)
        guard session.attempt.phase == .authenticating else { return }
        abandonOperation(for: client, returningTo: .readyToConfirm)
    }

    func adoptRecovery(
        _ client: AgentClient,
        result: AgentLastKnownResult,
        failure: AgentOnboardingFailure,
        change: AgentChangeStatus
    ) {
        var session = session(for: client)
        session.lastKnownResult = result
        session.attempt.phase = .recoveryRequired
        session.attempt.failure = failure
        session.attempt.changeStatus = change
        sessions[client] = session
    }

    private func applyCheckReport(
        _ client: AgentClient,
        _ report: AgentCheckReport,
        cancelled: Bool
    ) {
        var session = session(for: client)
        cancellations[client] = nil
        let lockedChange = recoveryLock(session.attempt.changeStatus)
        if cancelled || report.failure == .cancelled {
            session.attempt.phase = lockedChange != nil
                ? .recoveryRequired
                : (session.plan == nil ? .explanation : .readyToConfirm)
            session.attempt.failure = lockedChange.flatMap(recoveryFailure)
            sessions[client] = session
            return
        }
        if report.failure == nil {
            session.lastKnownResult = AgentLastKnownResult(
                outcome: report.outcome,
                checkedAt: clock(),
                targetSummary: report.targetSummary,
                discovery: report.discovery
            )
        } else if session.lastKnownResult == nil {
            session.lastKnownResult = AgentLastKnownResult(
                outcome: report.outcome,
                checkedAt: clock(),
                targetSummary: report.targetSummary,
                discovery: report.discovery
            )
        }
        if let lockedChange {
            session.plan = nil
            session.attempt.phase = .recoveryRequired
            session.attempt.changeStatus = lockedChange
            session.attempt.failure = report.failure ?? recoveryFailure(lockedChange)
            sessions[client] = session
            return
        }
        session.plan = report.plan
        if let failure = report.failure {
            session.attempt.phase = .needsAction
            session.attempt.failure = failure
            sessions[client] = session
            return
        }
        if report.outcome == .verifiedConnected {
            session.attempt.phase = .completed
            session.attempt.changeStatus = .notWritten
        } else if report.plan != nil {
            session.attempt.phase = .readyToConfirm
            session.attempt.changeStatus = .notWritten
        } else {
            session.attempt.phase = .needsAction
            session.attempt.changeStatus = .notWritten
        }
        session.attempt.failure = nil
        sessions[client] = session
    }

    private func applyCheckFailure(_ client: AgentClient, _ error: Error, cancelled: Bool) {
        var session = session(for: client)
        cancellations[client] = nil
        let failure = AgentOnboardingFailure.from(error)
        let lockedChange = recoveryLock(session.attempt.changeStatus)
        if cancelled || failure == .cancelled {
            session.attempt.phase = lockedChange != nil
                ? .recoveryRequired
                : (session.plan == nil ? .explanation : .readyToConfirm)
            session.attempt.failure = lockedChange.flatMap(recoveryFailure)
            sessions[client] = session
            return
        }
        session.attempt.phase = lockedChange != nil ? .recoveryRequired : .needsAction
        session.attempt.failure = failure
        if let lockedChange {
            session.attempt.changeStatus = lockedChange
            session.plan = nil
        }
        sessions[client] = session
    }

    private func recoveryLock(_ change: AgentChangeStatus) -> AgentChangeStatus? {
        switch change {
        case .restoreFailed: return change
        default: return nil
        }
    }

    private func recoveryFailure(_ change: AgentChangeStatus) -> AgentOnboardingFailure {
        switch change {
        default: return .restoreFailed
        }
    }

    private func applyApplyReport(_ client: AgentClient, _ report: AgentApplyReport) {
        var session = session(for: client)
        if let failure = report.failure {
            if client == .codex || client == .cursor || client == .grok,
               report.discovery != nil {
                // A local write may have succeeded before a lost response.
                // Discard the old approval plan: only a fresh read can offer
                // a new configuration action.
                session.plan = nil
            }
            session.attempt.failure = failure
            session.attempt.changeStatus = report.changeStatus
            switch report.changeStatus {
            case .restoreFailed:
                session.attempt.phase = .recoveryRequired
            case .restored:
                session.attempt.phase = .rolledBack
            case .verifiedAndKept:
                session.attempt.phase = .needsAction
            case .notWritten:
                session.attempt.phase = .needsAction
                if failure == .planChanged {
                    session.plan = nil
                }
            }
            if report.changeStatus == .verifiedAndKept || report.outcome == .verifiedConnected {
                session.lastKnownResult = AgentLastKnownResult(
                    outcome: report.outcome,
                    checkedAt: clock(),
                    targetSummary: report.targetSummary,
                    discovery: report.discovery
                )
            }
            sessions[client] = session
            return
        }
        session.lastKnownResult = AgentLastKnownResult(
            outcome: report.outcome,
            checkedAt: clock(),
            targetSummary: report.targetSummary,
            discovery: report.discovery
        )
        session.attempt.phase = report.changeStatus == .restored ? .rolledBack : .completed
        session.attempt.changeStatus = report.changeStatus
        session.attempt.failure = nil
        if report.changeStatus == .verifiedAndKept {
            session.plan = nil
        }
        sessions[client] = session
    }

    private func applyApplyFailure(_ client: AgentClient, _ error: Error) {
        let failure = AgentOnboardingFailure.from(error)
        let change: AgentChangeStatus
        switch failure {
        case .restoreFailed: change = .restoreFailed
        case .planChanged: change = .notWritten
        default: change = .notWritten
        }
        applyApplyReport(
            client,
            AgentApplyReport(
                outcome: session(for: client).lastKnownResult?.outcome ?? .notConfigured,
                changeStatus: change,
                failure: failure,
                targetSummary: session(for: client).lastKnownResult?.targetSummary ?? ""
            )
        )
    }
}
