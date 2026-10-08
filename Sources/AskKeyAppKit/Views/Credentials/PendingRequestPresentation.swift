import Foundation
import AskKeyBroker

/// One pending request as a sentence: "<caller> wants to use <credential>
/// to run <command>". The command comes from the App-derived display
/// summary of the bound request, never from the helper's own claims.
struct PendingRequestPresentation: Equatable {
    let sentence: EmphasizedSentence

    init(approval: BrokerPendingApproval) {
        let request = approval.request
        let caller = request.callerName ?? appLocalized("Local Agent")
        if request.operation == .read, let command = request.display?.commandSummary, !command.isEmpty {
            sentence = EmphasizedSentence(
                format: appLocalized("%1$@ wants to use %2$@ to run %3$@"),
                arguments: [caller, approval.displayCredentialName, command]
            )
        } else {
            sentence = EmphasizedSentence(
                format: Self.format(request.operation),
                arguments: [caller, approval.displayCredentialName]
            )
        }
    }

    static func expiry(deadline: Date?, now: Date) -> String {
        appLocalizedFormat("Expires in %@", FrozenCountdown.format(deadline: deadline, now: now))
    }

    private static func format(_ operation: BrokerApprovalOperation) -> String {
        switch operation {
        case .read: return appLocalized("%1$@ wants to use %2$@")
        case .create: return appLocalized("%1$@ wants to create %2$@")
        case .organize: return appLocalized("%@ wants to organize credentials")
        case .modify: return appLocalized("%1$@ wants to change %2$@")
        case .delete: return appLocalized("%1$@ wants to delete %2$@")
        }
    }
}
