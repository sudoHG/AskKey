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
    /// What a read hands the command if allowed, one line per variable.
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
            title = EmphasizedSentence(format: Self.titleFormat(request.operation, valueOnlyChange: valueOnlyChange),
                arguments: [requester, ApprovalCopy.quoted(credentialName)]).plainText
        }
        let display = request.operation == .read ? request.display : nil
        command = display?.commandLine
        receives = request.operation == .read ? Self.receives(display, credentialName: credentialName) : []
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
                ? appLocalized("%1$@ wants to replace the value of %2$@")
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
            ? appLocalized("You cancelled authentication. The credential was not delivered, and the request is still pending.")
            : appLocalized("You cancelled authentication. Nothing was changed, and the request is still pending.")
    }

    /// Variable names only; a multi-item credential's mapping is not opened
    /// before approval, so its items are described without names.
    static func receives(_ display: BrokerApprovalOperationRequest.Display?, credentialName: String) -> [ApprovalLine] {
        guard let display else { return [] }
        let name = ApprovalCopy.quoted(credentialName)
        guard let environment = display.environmentVariables, let files = display.temporaryFileVariables else {
            return [ApprovalLine(appLocalizedFormat(
                "The items of %@ that are set to be given to programs (names are shown after you approve)", name))]
        }
        let rows = environment.map {
            ApprovalLine(format: appLocalized("%1$@ · as environment variable %2$@"), plain: [name], code: [$0])
        } + files.map {
            ApprovalLine(format: appLocalized("%1$@ · as a temporary file (path in %2$@, removed within 5 minutes)"),
                plain: [name], code: [$0])
        }
        return rows.isEmpty ? [ApprovalLine(appLocalized("Nothing from this credential is given to the command"))] : rows
    }
}
