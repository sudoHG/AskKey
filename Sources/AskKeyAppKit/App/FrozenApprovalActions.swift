import AskKeyBroker

/// The card's stacked buttons: the approving action, the read card's timed
/// allowance, then Deny. A cancelled authentication keeps the same buttons in
/// the same order, so the default never moves to another decision.
enum FrozenApprovalActions {
    struct Button: Equatable {
        let title: String
        let role: ApprovalButtonRole
        let decision: BrokerApprovalDecision
        let identifier: String
        var help: String? = nil
    }

    /// A destructive approving action is drawn in red and is never the default.
    static func buttons(operation: BrokerApprovalOperation, timedAllowanceEnabled: Bool, minutes: Int = 30,
                        valueOnlyChange: Bool = false, destructive: Bool = false) -> [Button] {
        let title: String
        switch operation {
        case .read: title = appLocalized("Allow Once")
        case .create: title = appLocalized("Create credential button")
        case .modify: title = valueOnlyChange ? appLocalized("Replace") : appLocalized("Change")
        case .delete: title = appLocalized("Delete")
        case .organize: title = appLocalized("Apply")
        }
        var buttons = [Button(title: title, role: destructive ? .destructive : .primary, decision: .once,
                              identifier: "approval-allow-once")]
        if operation == .read, timedAllowanceEnabled {
            buttons.append(Button(title: appLocalizedFormat("Allow for %lld Minutes", minutes), role: .secondary,
                                  decision: .timedAllow(duration: nil), identifier: "approval-allow-timed",
                                  help: timedScope(minutes: minutes)))
        }
        buttons.append(Button(title: appLocalized("Deny"), role: .secondary, decision: .deny, identifier: "approval-deny"))
        return buttons
    }

    /// What the timed allowance covers, shown in Details and on hover.
    static func timedScope(minutes: Int) -> String {
        appLocalizedFormat("For %lld minutes, any agent or command in your Mac account can read this credential without asking. Changing or deleting it still needs your approval.", minutes)
    }

    static func titles(operation: BrokerApprovalOperation, timedAllowanceEnabled: Bool, minutes: Int = 30,
                       valueOnlyChange: Bool = false) -> [String] {
        buttons(operation: operation, timedAllowanceEnabled: timedAllowanceEnabled, minutes: minutes,
                valueOnlyChange: valueOnlyChange).map(\.title)
    }
}
