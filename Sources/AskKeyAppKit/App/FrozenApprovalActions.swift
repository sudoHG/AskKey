import AskKeyBroker

enum FrozenApprovalActions {
    static func titles(
        operation: BrokerApprovalOperation,
        timedAllowanceEnabled: Bool
    ) -> [String] {
        switch operation {
        case .read:
            return timedAllowanceEnabled
                ? [appLocalized("Allow Once"), appLocalizedFormat("Allow for %lld minutes", 30), appLocalized("Deny")]
                : [appLocalized("Allow Once"), appLocalized("Deny")]
        case .create: return [appLocalized("Approve Creation"), appLocalized("Deny")]
        case .modify: return [appLocalized("Approve Change"), appLocalized("Deny")]
        case .delete: return [appLocalized("Approve Deletion"), appLocalized("Deny")]
        }
    }
}
