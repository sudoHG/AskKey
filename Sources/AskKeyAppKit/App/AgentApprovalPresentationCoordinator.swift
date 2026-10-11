import Foundation
import AskKeyBroker

/// Owns the presentation queue independently of AppKit window construction.
@MainActor
final class AgentApprovalPresentationCoordinator {
    private let screenState: () -> AgentApprovalScreenState
    private let loadPending: () -> [BrokerPendingApproval]
    private let clock: () -> Date
    private let refreshExpiration: () -> Void
    private let lockedReminder: (String, String) -> Void
    private let feedback: (String) -> Void
    private let present: (BrokerPendingApproval, BrokerApprovalDecision?, @escaping (BrokerApprovalDecision?) -> Void) -> AgentApprovalPanelActions
    private let applyDecision: (BrokerPendingApproval, BrokerApprovalDecision) -> Void
    private var activeRequest: BrokerPendingApproval?
    private var presentationID: UUID?
    private var panel: AgentApprovalPanelActions?
    private var applyingDecision = false
    private var deferredRequestIDs: Set<String> = []
    var isPresenting: Bool { presentationID != nil }

    init(
        screenState: @escaping () -> AgentApprovalScreenState,
        loadPending: @escaping () -> [BrokerPendingApproval],
        clock: @escaping () -> Date = Date.init,
        refreshExpiration: @escaping () -> Void,
        lockedReminder: @escaping (String, String) -> Void,
        feedback: @escaping (String) -> Void,
        present: @escaping (BrokerPendingApproval, BrokerApprovalDecision?, @escaping (BrokerApprovalDecision?) -> Void) -> AgentApprovalPanelActions,
        applyDecision: @escaping (BrokerPendingApproval, BrokerApprovalDecision) -> Void
    ) {
        self.screenState = screenState
        self.loadPending = loadPending
        self.clock = clock
        self.refreshExpiration = refreshExpiration
        self.lockedReminder = lockedReminder
        self.feedback = feedback
        self.present = present
        self.applyDecision = applyDecision
    }

    func presentPendingApproval(
        operationID: String? = nil,
        cancelledAuthenticationDecision: BrokerApprovalDecision? = nil,
        userInitiated: Bool = false
    ) {
        let requests: [BrokerPendingApproval]
        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: screenState(), load: loadPending) {
        case .lockedReminder(let title, let body):
            if !applyingDecision { dismissActivePanel() }
            lockedReminder(title, body)
            if userInitiated { feedback("Unlock your Mac to review a pending request.") }
            return
        case .detailed(let loaded):
            requests = (loaded ?? []).filter { $0.expiresAt.map { $0 > clock() } != false }
        }
        // Authentication/commit may still be running after the panel closes.
        guard !applyingDecision else { return }
        deferredRequestIDs.formIntersection(Set(requests.map(\.requestID)))
        if let activeRequest {
            let stillPending = requests.contains { $0.requestID == activeRequest.requestID && $0.capability == activeRequest.capability }
            if stillPending, operationID == nil || operationID == activeRequest.request.operationID {
                if userInitiated { panel?.bringForward() }
                return
            }
            // Invalidate the old completion before closing its panel. It must
            // never apply a decision to a newly selected request.
            dismissActivePanel()
        }
        let eligible = userInitiated || operationID != nil
            ? requests
            : requests.filter { !deferredRequestIDs.contains($0.requestID) }
        guard let pending = AgentApprovalRequestSelection.select(eligible, operationID: operationID) else {
            if userInitiated { feedback("This request is no longer pending.") }
            return
        }
        deferredRequestIDs.remove(pending.requestID)
        activeRequest = pending
        let id = UUID()
        presentationID = id
        let actions = present(pending, cancelledAuthenticationDecision) { [weak self] decision in
            self?.finish(decision, pending: pending, presentationID: id)
        }
        if presentationID == id, !applyingDecision { panel = actions }
    }

    func decisionFinished() {
        activeRequest = nil
        presentationID = nil
        panel = nil
        applyingDecision = false
    }

    func refreshAfterResume() {
        // Refresh badges and terminal records even while the privacy gate is
        // closed; no request details need to be loaded to expire them.
        refreshExpiration()
        presentPendingApproval()
    }

    private func finish(_ decision: BrokerApprovalDecision?, pending: BrokerPendingApproval, presentationID id: UUID) {
        guard presentationID == id, !applyingDecision else { return }
        panel = nil
        let valid = screenState() == .unlocked
            && pending.expiresAt.map { $0 > clock() } != false
        if let decision, valid, loadPending().contains(where: {
            $0.requestID == pending.requestID && $0.capability == pending.capability
        }) {
            applyingDecision = true
            applyDecision(pending, decision)
            return
        }
        decisionFinished()
        if valid { deferredRequestIDs.insert(pending.requestID) }
        presentPendingApproval()
    }

    private func dismissActivePanel() {
        let previous = panel
        decisionFinished()
        previous?.dismiss()
    }
}
