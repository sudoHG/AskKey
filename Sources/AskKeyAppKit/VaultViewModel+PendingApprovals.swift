import Foundation
import AskKeyBroker
import AskKeyVault

extension VaultViewModel {
    /// Denies one waiting Agent request from Pending requests. Like Deny in
    /// the approval prompt, this needs no authentication.
    func denyPendingApproval(_ approval: BrokerPendingApproval) {
        do {
            _ = try Vault.shared.decideAgentApproval(
                requestID: approval.requestID,
                capability: approval.capability,
                decision: .deny
            )
        } catch where LocalApprovalDecision.showsError(error) {
            errorMessage = "Ask Key could not apply this decision. Open Pending requests to retry or reject it."
        } catch {
            // A paired iPhone decided it first (ADR 0014): no error.
        }
        pendingApprovalCount = Vault.shared.approvalRequests.pendingRequests().count
    }
}
