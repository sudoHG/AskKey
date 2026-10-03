import Foundation
import XCTest
@testable import AskKeyApp

/// Call-boundary evidence for 331-404 S1.
/// These assertions describe the new contract. On baseline ef90eae they must RED:
/// the Agent access page starts previews, and preview failures write
/// `VaultViewModel.errorMessage`.
@MainActor
final class AgentOnboardingCallBoundaryTests: AskKeyAppTestCase {
    func testCoordinatorAppearAndExplainDoNotStartChecks() async {
        let probe = OnboardingCheckProbe()
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        coordinator.appear()
        coordinator.explain(.codex)
        coordinator.disappear()
        XCTAssertEqual(probe.checkCount, 0)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testCoordinatorCheckFailureKeepsLastKnownResultAndOmitsGlobalError() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            if probe.checkCount == 1 {
                return AgentCheckReport(
                    outcome: .verifiedConnected,
                    targetSummary: "codex-ok",
                    plan: nil,
                    failure: nil
                )
            }
            throw AgentOnboardingFailure.timedOut
        }
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let coordinator = AgentOnboardingCoordinator(
            operations: probe.operations,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        viewModel.onboarding = coordinator

        await coordinator.startCheck(.codex)
        let kept = coordinator.session(for: .codex).lastKnownResult
        XCTAssertEqual(kept?.outcome, .verifiedConnected)
        XCTAssertEqual(kept?.targetSummary, "codex-ok")

        await coordinator.startCheck(.codex)
        let afterFailure = coordinator.session(for: .codex)
        XCTAssertEqual(afterFailure.lastKnownResult?.outcome, .verifiedConnected)
        XCTAssertEqual(afterFailure.lastKnownResult?.targetSummary, "codex-ok")
        XCTAssertEqual(afterFailure.attempt.phase, .needsAction)
        XCTAssertEqual(afterFailure.attempt.failure, .timedOut)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(afterFailure.attempt.changeStatus, .notWritten)
    }

    func testCoordinatorRejectsDuplicateCheckAndDropsLateCallback() async {
        let gate = LateCallbackGate()
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, cancellation in
            await gate.waitIfFirst()
            if cancellation.isCancelled {
                throw AgentOnboardingFailure.cancelled
            }
            return AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: "late",
                plan: nil,
                failure: nil
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        let first = Task { await coordinator.startCheck(.cursor) }
        await waitUntil { probe.checkCount >= 1 }
        let second = Task { await coordinator.startCheck(.cursor) }
        await second.value
        XCTAssertEqual(probe.checkCount, 1)
        XCTAssertEqual(coordinator.session(for: .cursor).attempt.phase, .checking)
        coordinator.abandonOperation(for: .cursor)
        await gate.release()
        await first.value
        XCTAssertNotEqual(coordinator.session(for: .cursor).lastKnownResult?.targetSummary, "late")
        XCTAssertNotEqual(coordinator.session(for: .cursor).attempt.phase, .checking)
    }

    func testTenAppearExplainCyclesDoNotStartChecks() async {
        let probe = OnboardingCheckProbe()
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        for _ in 0..<10 {
            coordinator.appear()
            for client in AgentClient.allCases {
                coordinator.explain(client)
            }
            coordinator.disappear()
        }
        XCTAssertEqual(probe.checkCount, 0)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testExistingConfigurationCheckDoesNotCreateWritePlan() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .existingConfigUnverified,
                targetSummary: "Cursor",
                plan: nil,
                failure: .verificationFailed
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.cursor)
        let session = coordinator.session(for: .cursor)
        XCTAssertNil(session.plan)
        XCTAssertEqual(session.lastKnownResult?.outcome, .existingConfigUnverified)
        XCTAssertEqual(session.attempt.phase, .needsAction)
        XCTAssertEqual(session.attempt.changeStatus, .notWritten)
        XCTAssertEqual(probe.applyCount, 0)
    }

    func testConfirmWritesOnlyAfterAuthenticationAndRecordsVerifiedResult() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: "Grok CLI",
                plan: sampleOnboardingPlan(client: .grok),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            AgentApplyReport(
                outcome: .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: "Grok CLI"
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.grok)
        XCTAssertEqual(probe.applyCount, 0)
        await coordinator.confirm(.grok)
        XCTAssertEqual(probe.applyCount, 1)
        XCTAssertEqual(coordinator.session(for: .grok).attempt.phase, .completed)
        XCTAssertEqual(coordinator.session(for: .grok).attempt.changeStatus, .verifiedAndKept)
        XCTAssertEqual(coordinator.session(for: .grok).lastKnownResult?.outcome, .verifiedConnected)
        XCTAssertNil(coordinator.session(for: .grok).plan)
    }

    func testRestoreFailedAndRemoteUnknownBlockOrdinaryWriteRetry() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: sampleOnboardingPlan(client: client),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            XCTFail("ordinary confirm must not write after recoveryRequired")
            return AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .notWritten,
                failure: .cancelled,
                targetSummary: ""
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        coordinator.adoptRecovery(
            .codex,
            result: AgentLastKnownResult(
                outcome: .notConfigured,
                checkedAt: Date(timeIntervalSince1970: 1),
                targetSummary: "Codex"
            ),
            failure: .restoreFailed,
            change: .restoreFailed
        )
        await coordinator.confirm(.codex)
        XCTAssertEqual(probe.applyCount, 0)

    }

    func testUnconfirmedLocalDiscoveryWriteRequiresFreshCheckBeforeAnotherConfirm() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(outcome: .configuredUnverified, targetSummary: client.rawValue,
                             plan: sampleOnboardingPlan(client: client), failure: nil,
                             discovery: .untrusted)
        }
        probe.applyHandler = { client, _, _ in
            AgentApplyReport(outcome: .configuredUnverified, changeStatus: .verifiedAndKept,
                             failure: .discoverySetupFailed, targetSummary: client.rawValue,
                             discovery: .unavailable)
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        for client in [AgentClient.codex, .cursor, .grok] {
            await coordinator.startCheck(client)
            await coordinator.confirm(client)
            XCTAssertNil(coordinator.session(for: client).plan)
            XCTAssertEqual(coordinator.session(for: client).attempt.phase, .needsAction)
            await coordinator.confirm(client)
        }
        XCTAssertEqual(probe.applyCount, 3, "An uncertain write must not reuse its approval plan")
    }

    func testApplyPlanChangedAndRestoredFailuresStayTyped() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: "Codex",
                plan: sampleOnboardingPlan(client: .codex),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .notWritten,
                failure: .planChanged,
                targetSummary: "Codex"
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        await coordinator.confirm(.codex)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.phase, .needsAction)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.failure, .planChanged)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.changeStatus, .notWritten)
        XCTAssertNil(coordinator.session(for: .codex).plan)

        probe.applyHandler = { _, _, _ in
            AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .restored,
                failure: .verificationFailed,
                targetSummary: "Codex"
            )
        }
        await coordinator.startCheck(.codex)
        await coordinator.confirm(.codex)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.phase, .rolledBack)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.changeStatus, .restored)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.failure, .verificationFailed)

        let restoreProbe = OnboardingCheckProbe()
        restoreProbe.checkHandler = probe.checkHandler
        restoreProbe.applyHandler = { _, _, _ in
            AgentApplyReport(
                outcome: .notConfigured,
                changeStatus: .restoreFailed,
                failure: .restoreFailed,
                targetSummary: "Codex"
            )
        }
        let retry = AgentOnboardingCoordinator(operations: restoreProbe.operations)
        await retry.startCheck(.codex)
        await retry.confirm(.codex)
        XCTAssertEqual(retry.session(for: .codex).attempt.phase, .recoveryRequired)
        XCTAssertEqual(retry.session(for: .codex).attempt.changeStatus, .restoreFailed)
    }

    func testWriteContinuesAfterDisappear() async {
        let gate = LateCallbackGate()
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: "Cursor",
                plan: sampleOnboardingPlan(client: .cursor),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            await gate.waitIfFirst()
            return AgentApplyReport(
                outcome: .verifiedConnected,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: "Cursor"
            )
        }
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.cursor)
        let write = Task { await coordinator.confirm(.cursor) }
        await waitUntil { coordinator.hasInFlightWrite }
        coordinator.disappear()
        XCTAssertTrue(coordinator.hasInFlightWrite)
        XCTAssertEqual(probe.applyCount, 1)
        await gate.release()
        await write.value
        XCTAssertEqual(coordinator.session(for: .cursor).attempt.changeStatus, .verifiedAndKept)
        XCTAssertFalse(coordinator.hasInFlightWrite)
    }

    func testCancelledAuthenticationDoesNotWrite() async {
        let probe = OnboardingCheckProbe()
        probe.checkHandler = { _, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: "codex",
                plan: AgentOnboardingPlan(
                    client: .codex,
                    createdAt: Date(),
                    targetIdentity: "codex",
                    scopeSummary: "add",
                    configurationPresent: false,
                    verifiesOnly: false,
                    preconditionSummary: "backup"
                ),
                failure: nil
            )
        }
        probe.authenticateResult = .cancelled
        let coordinator = AgentOnboardingCoordinator(operations: probe.operations)
        await coordinator.startCheck(.codex)
        await coordinator.confirm(.codex)
        XCTAssertEqual(probe.applyCount, 0)
        XCTAssertEqual(coordinator.session(for: .codex).attempt.phase, .readyToConfirm)
        XCTAssertNil(coordinator.session(for: .codex).attempt.failure)
    }

    func testPreviewFailureDoesNotWriteGlobalErrorMessage() async {
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let preview = await viewModel.loadAgentClientPreview(.cursor) {
            throw AgentOnboardingFailure.timedOut
        }
        XCTAssertNil(preview)
        XCTAssertNil(
            viewModel.errorMessage,
            "an Agent access check failure must stay on the client row, not the global alert"
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for condition")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class LateCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiting = false

    func waitIfFirst() async {
        let shouldWait: Bool = lock.withLock {
            if waiting { return false }
            waiting = true
            return true
        }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func release() async {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }
}

private final class OnboardingCheckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var checks = 0
    private var applies = 0
    var checkHandler: (@Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport)?
    var applyHandler: (@Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport)?
        var authenticateResult: AgentAuthenticationOutcome = .confirmed
        var sessionValid = true

    var checkCount: Int { lock.withLock { checks } }
    var applyCount: Int { lock.withLock { applies } }

    var operations: AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { client, cancellation in
                self.lock.withLock { self.checks += 1 }
                if let checkHandler = self.checkHandler {
                    return try await checkHandler(client, cancellation)
                }
                return AgentCheckReport(
                    outcome: .notConfigured,
                    targetSummary: client.rawValue,
                    plan: nil,
                    failure: nil
                )
            },
            apply: { client, plan, cancellation in
                self.lock.withLock { self.applies += 1 }
                if let applyHandler = self.applyHandler {
                    return try await applyHandler(client, plan, cancellation)
                }
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { self.authenticateResult },
            revalidateWriteSession: { self.sessionValid }
        )
    }
}

private func sampleOnboardingPlan(client: AgentClient) -> AgentOnboardingPlan {
    AgentOnboardingPlan(
        client: client,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        targetIdentity: client.rawValue,
        scopeSummary: "scope",
        configurationPresent: false,
        verifiesOnly: false,
        preconditionSummary: "backup"
    )
}
