import AskKeyBroker

/// Button titles that state each decision's consequence.
enum FrozenApprovalActions {
    struct Primary: Equatable {
        let title: String
        let role: ApprovalButtonRole
    }

    static func primary(operation: BrokerApprovalOperation, valueOnlyChange: Bool = false,
                        steps: Int? = nil, destructive: Bool = false) -> Primary {
        switch operation {
        case .read: return Primary(title: appLocalized("Allow Once"), role: .primary)
        case .create: return Primary(title: appLocalized("Create Credential"), role: .primary)
        case .modify:
            return Primary(title: valueOnlyChange ? appLocalized("Replace Value") : appLocalized("Save Changes"),
                role: .primary)
        case .delete: return Primary(title: appLocalized("Move to Recycle Bin"), role: .destructive)
        case .organize:
            let title: String
            switch steps {
            case nil: title = appLocalized("Apply Steps")
            case 1?: title = appLocalized("Apply 1 Step")
            case let count?: title = appLocalizedFormat("Apply %lld Steps", count)
            }
            return Primary(title: title, role: destructive ? .destructive : .primary)
        }
    }

    static func timed(minutes: Int) -> String {
        appLocalizedFormat("Allow for %lld Minutes", minutes)
    }

    /// What the timed allowance covers, stated under its button.
    static func timedScope(minutes: Int) -> String {
        appLocalizedFormat("For %lld minutes, any agent or command in your Mac account can read this credential without asking. Changing or deleting it still needs your approval.", minutes)
    }

    /// Retries the decision the user chose before cancelling authentication.
    static func retry(_ decision: BrokerApprovalDecision, primary: Primary, minutes: Int) -> String {
        if case .timedAllow = decision {
            return appLocalizedFormat("Authenticate and %@", timed(minutes: minutes))
        }
        return appLocalizedFormat("Authenticate and %@", primary.title)
    }

    static func titles(operation: BrokerApprovalOperation, timedAllowanceEnabled: Bool, minutes: Int = 30,
                       valueOnlyChange: Bool = false, steps: Int? = nil) -> [String] {
        let primary = primary(operation: operation, valueOnlyChange: valueOnlyChange, steps: steps).title
        if operation == .read, timedAllowanceEnabled {
            return [primary, timed(minutes: minutes), appLocalized("Deny")]
        }
        return [primary, appLocalized("Deny")]
    }
}
