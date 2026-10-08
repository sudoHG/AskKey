import Foundation
import AskKeyBroker

struct FrozenAgentTextWrite {
    let operationID: String
    let digest: String
    let approvalRequest: BrokerApprovalOperationRequest
    let credentialExpiresAt: Date?
    let mutation: FrozenAgentTextMutation
    var beforeRecord: CredentialRecord? = nil
    var summary: BrokerCredentialWriteSummary? = nil
    var groupAssignment: String? = nil
}
