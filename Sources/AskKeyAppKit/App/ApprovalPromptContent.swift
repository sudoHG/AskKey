import AskKeyBroker

/// The card's title and subtitle, derived from the pending request and, for
/// write and organize cards, their frozen summaries. The requester's name is
/// self-declared; the command comes from the App-derived display summary.
struct ApprovalPromptContent: Equatable {
    /// One sentence naming who wants to do what with which object.
    let title: String
    /// Write and organize cards: one short line under the title. Read cards
    /// show their command there instead.
    let subtitle: String?
    /// Read cards: the one-line command, already middle-truncated by the display summary.
    let commandSummary: String?
    let fullCommand: String?

    init(request: BrokerApprovalOperationRequest, credentialName: String,
         write: FrozenWriteSummaryContent? = nil, organization: FrozenOrganizationSummaryContent? = nil) {
        let requester = ApprovalCopy.requester(request)
        switch request.operation {
        case .read, .create, .delete:
            title = Self.sentence(Self.titleFormat(request.operation), requester, credentialName)
        case .modify:
            title = Self.modifyTitle(requester: requester, credentialName: credentialName, write: write)
        case .organize:
            title = Self.sentence(Self.titleFormat(.organize), requester)
        }
        switch request.operation {
        case .read: subtitle = nil
        case .create, .modify: subtitle = write?.subtitle
        case .delete: subtitle = appLocalized("Moves to the Recycle Bin; restorable for 30 days")
        case .organize: subtitle = organization?.subtitle
        }
        let display = request.operation == .read ? request.display : nil
        commandSummary = display?.commandSummary
        fullCommand = display?.commandLine
    }

    /// Shared with the pending list so both say the same sentence.
    static func titleFormat(_ operation: BrokerApprovalOperation) -> String {
        switch operation {
        case .read: return appLocalized("“%1$@” wants to use “%2$@”")
        case .create: return appLocalized("“%1$@” wants to create the credential “%2$@”")
        case .modify: return appLocalized("“%1$@” wants to change “%2$@”")
        case .delete: return appLocalized("“%1$@” wants to delete “%2$@”")
        case .organize: return appLocalized("“%@” wants to organize your groups")
        }
    }

    /// A change that only replaces values names them: the value of the
    /// credential, or the replaced items when others stay as they are.
    private static func modifyTitle(requester: String, credentialName: String,
                                    write: FrozenWriteSummaryContent?) -> String {
        guard let write, write.valueOnlyChange else {
            return sentence(titleFormat(.modify), requester, credentialName)
        }
        let replaced = write.components.filter { $0.tag == .replaced }.map(\.name)
        if replaced.count < write.components.count {
            return sentence(appLocalized("“%1$@” wants to replace %3$@ in “%2$@”"), requester, credentialName,
                            replaced.joined(separator: appLocalized("List separator")))
        }
        return replaced.count == 1
            ? sentence(appLocalized("“%1$@” wants to replace the value of “%2$@”"), requester, credentialName)
            : sentence(appLocalized("“%1$@” wants to replace the values of “%2$@”"), requester, credentialName)
    }

    private static func sentence(_ format: String, _ arguments: String...) -> String {
        EmphasizedSentence(format: format, arguments: arguments).plainText
    }
}
