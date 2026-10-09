import AskKeyBroker

/// Copy shown by the approval card, derived from the pending request. The
/// requester's name and purpose are self-declared; the command, working
/// directory and delivered names come from the App-derived display summary.
struct ApprovalPromptContent: Equatable {
    struct Row: Equatable {
        let label: String
        let value: String
        let monospaced: Bool
    }

    let operation: BrokerApprovalOperation
    let requester: String
    let title: String
    /// The whole command line, never shortened.
    let command: String?
    /// What a read hands the command if allowed: a heading naming the
    /// credential and how many items, then one line per variable.
    let receivesHeading: String
    let receives: [ApprovalLine]
    let purpose: String?
    let detailRows: [Row]

    init(request: BrokerApprovalOperationRequest, credentialName: String,
         valueOnlyChange: Bool = false, organizationSteps: Int? = nil) {
        let requester = ApprovalCopy.requester(request)
        self.requester = requester
        operation = request.operation
        if request.operation == .organize {
            title = Self.organizationTitle(requester: requester, steps: organizationSteps)
        } else {
            let object = request.operation == .modify && valueOnlyChange
                ? ApprovalCopy.credentialValue(credentialName) : ApprovalCopy.quoted(credentialName)
            title = EmphasizedSentence(format: Self.titleFormat(request.operation, valueOnlyChange: valueOnlyChange),
                arguments: [requester, object]).plainText
        }
        let display = request.operation == .read ? request.display : nil
        command = display?.commandLine
        (receivesHeading, receives) = request.operation == .read
            ? Self.receives(display, credentialName: credentialName) : ("", [])
        purpose = request.callerPurpose.flatMap { $0.isEmpty ? nil : $0 }
        var rows: [Row] = []
        if let directory = display?.workingDirectory, !directory.isEmpty {
            rows.append(Row(label: appLocalized("Runs in"), value: directory, monospaced: true))
        }
        rows.append(Row(label: appLocalized("Requested by"),
            value: appLocalizedFormat("%@ (name provided by the requester; Ask Key can't verify it)", requester),
            monospaced: false))
        detailRows = rows
    }

    /// Shared with the pending list so both name the object the same way.
    static func titleFormat(_ operation: BrokerApprovalOperation, valueOnlyChange: Bool = false) -> String {
        switch operation {
        case .read: return appLocalized("%1$@ wants to use the credential %2$@")
        case .create: return appLocalized("%1$@ wants to create the credential %2$@")
        case .modify:
            return valueOnlyChange
                ? appLocalized("%1$@ wants to replace %2$@")
                : appLocalized("%1$@ wants to change the credential %2$@")
        case .delete: return appLocalized("%1$@ wants to delete the credential %2$@")
        case .organize: return appLocalized("%@ wants to reorganize your groups")
        }
    }

    static func organizationTitle(requester: String, steps: Int?) -> String {
        guard let steps else { return appLocalizedFormat("%@ wants to reorganize your groups", requester) }
        return steps == 1
            ? appLocalizedFormat("%@ wants to reorganize your groups (1 step)", requester)
            : appLocalizedFormat("%1$@ wants to reorganize your groups (%2$lld steps)", requester, steps)
    }

    var cancelledAuthenticationNote: String {
        operation == .read
            ? appLocalized("You cancelled authentication. Nothing was given to the command, and the request is still pending.")
            : appLocalized("You cancelled authentication. Nothing was changed, and the request is still pending.")
    }

    /// Variable names only; a multi-item credential's mapping is not opened
    /// before approval, so its items are described without names.
    static func receives(_ display: BrokerApprovalOperationRequest.Display?,
                         credentialName: String) -> (heading: String, rows: [ApprovalLine]) {
        let heading = appLocalized("If you allow, this command receives")
        guard let display else { return (heading, []) }
        let name = ApprovalCopy.quoted(credentialName)
        guard let environment = display.environmentVariables, let files = display.temporaryFileVariables else {
            return (heading, [ApprovalLine(appLocalizedFormat(
                "The items of %@ that are set to be given to programs (names are shown after you approve)", name))])
        }
        let rows = environment.map { ApprovalLine(format: appLocalized("→ Environment variable %@"), code: [$0]) }
            + files.map { ApprovalLine(format: appLocalized("→ Temporary file (path in %@, removed within 5 minutes)"), code: [$0]) }
        switch rows.count {
        case 0: return (heading, [ApprovalLine(appLocalized("Nothing from this credential is given to the command"))])
        case 1: return (appLocalizedFormat("If you allow, this command receives 1 item from %@", name), rows)
        default:
            return (appLocalizedFormat("If you allow, this command receives %1$lld items from %2$@", rows.count, name), rows)
        }
    }
}
