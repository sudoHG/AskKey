import Foundation
import AskKeyBroker

/// One pending request as a sentence that names the object the way the
/// approval card's title does. The command comes from the App-derived display
/// summary of the bound request, never from the helper's own claims.
struct PendingRequestPresentation: Equatable {
    let sentence: EmphasizedSentence

    init(approval: BrokerPendingApproval) {
        let request = approval.request
        let requester = ApprovalCopy.requester(request)
        let credential = ApprovalCopy.quoted(approval.displayCredentialName)
        if request.operation == .read, let command = request.display?.commandSummary, !command.isEmpty {
            sentence = EmphasizedSentence(
                format: appLocalized("%1$@ wants to use the credential %2$@ to run %3$@"),
                arguments: [requester, credential, command]
            )
        } else if request.operation == .organize {
            sentence = EmphasizedSentence(format: ApprovalPromptContent.titleFormat(.organize), arguments: [requester])
        } else {
            sentence = EmphasizedSentence(
                format: ApprovalPromptContent.titleFormat(request.operation),
                arguments: [requester, credential]
            )
        }
    }

    static func expiry(deadline: Date?, now: Date) -> String {
        appLocalizedFormat("Expires in %@", FrozenCountdown.format(deadline: deadline, now: now))
    }
}
