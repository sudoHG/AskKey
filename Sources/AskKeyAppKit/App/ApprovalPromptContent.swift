import AppKit
import AskKeyBroker

/// Copy and detail rows shown by the approval prompt, derived from the pending
/// request. Caller and purpose are self-declared; the command, working
/// directory and delivered names come from the App-derived display summary.
struct ApprovalPromptContent: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        let monospaced: Bool
    }

    let operation: BrokerApprovalOperation
    let title: String
    /// One-line target summary, already middle-truncated by the display summary.
    let commandSummary: String?
    let fullCommand: String?
    let rows: [Row]

    init(request: BrokerApprovalOperationRequest, credentialName: String) {
        let caller = request.callerName ?? appLocalized("Local Agent")
        operation = request.operation
        switch request.operation {
        case .read: title = appLocalizedFormat("“%@” wants to use “%@”", caller, credentialName)
        case .create: title = appLocalizedFormat("“%@” wants to create “%@”", caller, credentialName)
        case .modify: title = appLocalizedFormat("“%@” wants to modify “%@”", caller, credentialName)
        case .delete: title = appLocalizedFormat("“%@” wants to delete “%@”", caller, credentialName)
        }
        let display = request.operation == .read ? request.display : nil
        commandSummary = display?.commandSummary
        fullCommand = display?.commandLine
        var rows: [Row] = []
        if let delivered = Self.deliveredNames(display) {
            rows.append(Row(label: appLocalized("Delivers"), value: delivered, monospaced: false))
        }
        if let directory = display?.workingDirectory, !directory.isEmpty {
            rows.append(Row(label: appLocalized("Location"), value: directory, monospaced: false))
        }
        if let purpose = request.callerPurpose, !purpose.isEmpty {
            rows.append(Row(
                label: appLocalized("Stated purpose"),
                value: appLocalizedFormat("%@ (self-declared, unverified)", purpose),
                monospaced: false
            ))
        }
        if request.operation == .delete {
            rows.append(Row(
                label: appLocalized("Destination"),
                value: appLocalized("Recycle Bin · Recoverable for 30 days"),
                monospaced: false
            ))
        }
        self.rows = rows
    }

    /// Rows for Details. The full command is added when the one-line summary
    /// cannot show all of it.
    func detailRows(commandFits: Bool) -> [Row] {
        guard let fullCommand, !fullCommand.isEmpty, !commandFits else { return rows }
        return [Row(label: appLocalized("Command"), value: fullCommand, monospaced: true)] + rows
    }

    var cancelledAuthenticationNote: String {
        operation == .read
            ? appLocalized("You cancelled authentication. The credential was not delivered, and the request is still pending.")
            : appLocalized("You cancelled authentication. Nothing was changed, and the request is still pending.")
    }

    var retryTitle: String {
        operation == .read ? appLocalized("Authenticate and allow") : appLocalized("Authenticate and approve")
    }

    /// Names only: nil when the mapping is unavailable before approval
    /// (bundles), so the prompt shows no delivered names at all.
    static func deliveredNames(_ display: BrokerApprovalOperationRequest.Display?) -> String? {
        guard let display,
              let environment = display.environmentVariables,
              let files = display.temporaryFileVariables else { return nil }
        let names = environment + files.map { appLocalizedFormat("%@ (file)", $0) }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: appLocalized("List separator"))
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
