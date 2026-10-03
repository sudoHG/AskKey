import AskKeyBroker

enum FrozenApprovalActions {
    static func titles(
        operation: BrokerApprovalOperation,
        timedAllowanceEnabled: Bool
    ) -> [String] {
        switch operation {
        case .read:
            return timedAllowanceEnabled
                ? ["仅本次", "允许 30 分钟", "拒绝"] // i18n-literal: Preserve existing timed read-approval labels until #83.
                : ["仅本次", "拒绝"] // i18n-literal: Preserve existing one-time read-approval labels until #83.
        case .create: return ["批准创建", "拒绝"] // i18n-literal: Preserve existing creation-approval labels until #83.
        case .modify: return ["批准修改", "拒绝"] // i18n-literal: Preserve existing modification-approval labels until #83.
        case .delete: return ["批准删除", "拒绝"] // i18n-literal: Preserve existing deletion-approval labels until #83.
        }
    }
}
