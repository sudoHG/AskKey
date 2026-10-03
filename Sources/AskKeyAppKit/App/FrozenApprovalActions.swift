import AskKeyBroker

enum FrozenApprovalActions {
    static func titles(
        operation: BrokerApprovalOperation,
        timedAllowanceEnabled: Bool
    ) -> [String] {
        switch operation {
        case .read:
            return timedAllowanceEnabled
                ? ["仅本次", "允许 30 分钟", "拒绝"]
                : ["仅本次", "拒绝"]
        case .create: return ["批准创建", "拒绝"]
        case .modify: return ["批准修改", "拒绝"]
        case .delete: return ["批准删除", "拒绝"]
        }
    }
}
