import AskKeyBroker

enum AgentApprovalRequestSelection {
    static func select(
        _ pending: [BrokerPendingApproval],
        operationID: String?
    ) -> BrokerPendingApproval? {
        guard let operationID else { return pending.first }
        return pending.first { $0.request.operationID == operationID }
    }
}
