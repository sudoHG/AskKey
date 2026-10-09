import AppKit
import AskKeyBroker

/// The rows under Details: a label and a value each, in a fixed order per
/// card. Nothing here repeats the card's title or subtitle.
struct ApprovalDetailsContent: Equatable {
    struct Line: Equatable {
        var tag: ApprovalTag? = nil
        let text: ApprovalLine
        /// A second line in the secondary color, such as a step's result.
        var note: String? = nil
    }

    enum Value: Equatable {
        case text(String)
        case code(String)
        case lines([Line])
        /// Removed words struck through, added words highlighted, then the
        /// removed phrases.
        case diff(ApprovalTextDiff)
        /// New values, masked until viewed with another authentication.
        case revealableValue
    }

    struct Row: Equatable {
        let label: String
        let value: Value
    }

    let rows: [Row]

    init(request: BrokerApprovalOperationRequest, credentialName: String, write: FrozenWriteSummaryContent? = nil,
         organization: FrozenOrganizationSummaryContent? = nil, timedAllowanceEnabled: Bool = false,
         timedAllowanceMinutes: Int = 30) {
        var rows = [Row(label: appLocalized("Requested by"),
                        value: .text(appLocalizedFormat("%@ (not verified)", ApprovalCopy.requester(request))))]
        if let purpose = request.callerPurpose, !purpose.isEmpty {
            rows.append(Row(label: appLocalized("Purpose"), value: .text(appLocalizedFormat("%@ (not verified)", purpose))))
        }
        switch request.operation {
        case .read:
            if let display = request.display {
                rows.append(Row(label: appLocalized("Command"), value: .code(display.commandLine)))
                if let directory = display.workingDirectory, !directory.isEmpty {
                    rows.append(Row(label: appLocalized("Runs in"), value: .code(directory)))
                }
                rows.append(Row(label: appLocalized("Hands over"),
                                value: .lines(Self.handsOver(display, credentialName: credentialName))))
            }
            if timedAllowanceEnabled {
                rows.append(Row(label: appLocalizedFormat("%lld minutes", timedAllowanceMinutes),
                                value: .text(FrozenApprovalActions.timedScope(minutes: timedAllowanceMinutes))))
            }
        case .create, .modify, .delete:
            if let write {
                rows += Self.writeRows(write)
            } else if request.operation != .delete {
                rows.append(Row(label: appLocalized("Value"), value: .revealableValue))
            }
        case .organize:
            rows += (organization?.rows ?? []).map { step in
                Row(label: appLocalizedFormat("Step %lld", step.number),
                    value: .lines([Line(tag: step.tag, text: ApprovalLine(step.title), note: step.detail)]))
            }
        }
        self.rows = rows
    }

    /// One line per variable the command gets. A credential with a variable
    /// has one item, named after the credential; a multi-item credential's
    /// mapping is not opened before approval, so its items stay unnamed.
    private static func handsOver(_ display: BrokerApprovalOperationRequest.Display, credentialName: String) -> [Line] {
        guard let environment = display.environmentVariables, let files = display.temporaryFileVariables else {
            return [Line(text: ApprovalLine(appLocalizedFormat(
                "The items of %@ that are set to be given to programs (names are shown after you approve)",
                ApprovalCopy.quoted(credentialName))))]
        }
        let lines = environment.map {
            Line(text: ApprovalLine(format: appLocalized("%1$@ → environment variable %2$@"), plain: [credentialName], code: [$0]))
        } + files.map {
            Line(text: ApprovalLine(format: appLocalized("%1$@ → temporary file %2$@"), plain: [credentialName], code: [$0]))
        }
        return lines.isEmpty ? [Line(text: ApprovalLine(appLocalized("Nothing from this credential is given to the command")))] : lines
    }

    private static func writeRows(_ write: FrozenWriteSummaryContent) -> [Row] {
        var rows: [Row] = []
        switch write.operation {
        case .create:
            rows.append(Row(label: appLocalized("Contents"), value: .lines(write.components.map { component in
                Line(text: ApprovalLine(format: "%@", code: [component.name]) + ApprovalLine(" · ")
                    + ApprovalCopy.delivery(component.delivery))
            })))
            if !write.instructions.isEmpty {
                rows.append(Row(label: appLocalized("Instructions"), value: .text(write.instructions)))
            }
        case .modify:
            let changed = write.changedComponents
            if !changed.isEmpty {
                rows.append(Row(label: appLocalized("Changes"), value: .lines(changed.map {
                    Line(tag: $0.tag, text: ApprovalLine(format: "%@", code: [$0.name]))
                })))
            }
            if let diff = write.instructionsDiff {
                rows.append(Row(label: appLocalized("Instructions"), value: .diff(diff)))
            }
            if let group = write.groupChange {
                let after = group.createsGroup ? appLocalizedFormat("%@ (new group)", group.after) : group.after
                rows.append(Row(label: appLocalized("Group"), value: .text(group.before + " → " + after)))
            }
        case .delete:
            rows.append(Row(label: appLocalized("Contents"), value: .lines(write.components.map {
                Line(text: ApprovalLine(format: "%@", code: [$0.name]))
            })))
        case .read, .organize:
            break
        }
        if !write.valueComponents.isEmpty {
            rows.append(Row(label: appLocalized("Value"), value: .revealableValue))
        }
        return rows
    }

    /// One label column for every card in the current language, wide enough
    /// for the longest label.
    static func labelWidth() -> CGFloat {
        let labels = ["Requested by", "Purpose", "Command", "Runs in", "Hands over", "Contents", "Instructions",
                      "Changes", "Group", "Value"].map { appLocalized($0) }
            + [appLocalizedFormat("%lld minutes", 999), appLocalizedFormat("Step %lld", 64)]
        let font = NSFont.systemFont(ofSize: 12)
        return ceil(labels.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0) + 1
    }
}
