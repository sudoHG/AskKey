import AppKit
import AskKeyBroker

/// The card's title, subtitle and Details rows, derived from the pending
/// request and, for write and organize cards, their frozen summaries. The
/// requester's name and purpose are self-declared; the command, working
/// directory and delivered names come from the App-derived display summary.
struct ApprovalPromptContent: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        var monospaced = false
    }

    /// One sentence naming who wants to do what with which object.
    let title: String
    /// Write and organize cards: one short line under the title. Read cards
    /// show their command there instead.
    let subtitle: String?
    /// Read cards: the one-line command, already middle-truncated by the display summary.
    let commandSummary: String?
    let fullCommand: String?
    let rows: [Row]

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
        var rows: [Row] = []
        if let display {
            rows.append(Row(label: appLocalized("Command gets"), value: Self.receives(display)))
            if let directory = display.workingDirectory, !directory.isEmpty {
                rows.append(Row(label: appLocalized("Runs in"), value: directory, monospaced: true))
            }
        }
        rows.append(Row(label: appLocalized("Requested by"),
            value: appLocalizedFormat("%@ (name provided by the requester; Ask Key can't verify it)", requester)))
        if let purpose = request.callerPurpose, !purpose.isEmpty {
            rows.append(Row(label: appLocalized("Stated purpose"), value: appLocalizedFormat("%@ (not verified)", purpose)))
        }
        self.rows = rows
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

    /// What the command gets and how, one line per variable. A multi-item
    /// credential's mapping is not opened before approval, so its items are
    /// described without names.
    static func receives(_ display: BrokerApprovalOperationRequest.Display) -> String {
        guard let environment = display.environmentVariables, let files = display.temporaryFileVariables else {
            return appLocalized("The items set to be given to programs (names are shown after you approve)")
        }
        let lines = environment.map { appLocalizedFormat("Environment variable %@", $0) }
            + files.map { appLocalizedFormat("Temporary file (path in %@, removed within 5 minutes)", $0) }
        return lines.isEmpty
            ? appLocalized("Nothing from this credential is given to the command")
            : lines.joined(separator: "\n")
    }

    /// Rows for Details. The full command leads when the one-line subtitle
    /// cannot show all of it.
    func detailRows(commandFits: Bool) -> [Row] {
        guard let fullCommand, !fullCommand.isEmpty, !commandFits else { return rows }
        return [Row(label: appLocalized("Command"), value: fullCommand, monospaced: true)] + rows
    }

    /// Whether "to run <command>" shows the whole command on one line of the
    /// given width: not truncated by the display summary and not clipped.
    func commandFits(prefix: String, width: CGFloat) -> Bool {
        guard let commandSummary, commandSummary == fullCommand else { return false }
        let prefixWidth = (prefix + " " as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).width
        let commandWidth = (commandSummary as NSString).size(
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]
        ).width
        return prefixWidth + commandWidth <= width
    }
}
