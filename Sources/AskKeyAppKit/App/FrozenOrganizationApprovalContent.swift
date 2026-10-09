import SwiftUI
import AskKeyBroker

/// Each frozen step as a sentence. Counts come from the summary, which
/// records them as they stand when that step runs.
struct FrozenOrganizationSummaryContent: Equatable {
    struct Row: Equatable {
        let number: Int
        let tag: ApprovalTag?
        let title: String
        let detail: String?
    }

    let rows: [Row]
    /// Deleting or merging groups cannot be undone in one step.
    let isDestructive: Bool

    init(summary: BrokerOrganizationSummary) {
        rows = summary.operations.enumerated().map { index, operation in
            let tag: ApprovalTag?
            let title: String
            let detail: String?
            switch operation {
            case .move(let credential, let from, let to):
                tag = nil
                title = appLocalizedFormat("Move the credential %1$@ from %2$@ to %3$@",
                    ApprovalCopy.quoted(credential), ApprovalCopy.group(from), ApprovalCopy.group(to))
                detail = nil
            case .createGroup(let name):
                tag = nil
                title = appLocalizedFormat("Create the group %@", ApprovalCopy.quoted(name))
                detail = nil
            case .existingGroup(let name, let members, let hidden):
                tag = .noChange
                title = appLocalizedFormat("Create the group %@", ApprovalCopy.quoted(name))
                detail = ApprovalCopy.sentences([
                    appLocalized("This group already exists, so nothing is created or changed."),
                    Self.contents(members: members, hidden: hidden),
                ])
            case .renameGroup(let from, let to, let members, let hidden):
                tag = nil
                title = appLocalizedFormat("Rename the group %1$@ to %2$@", ApprovalCopy.quoted(from), ApprovalCopy.quoted(to))
                detail = Self.contents(members: members, hidden: hidden)
            case .mergeGroup(let from, let to, let members, let hidden, let targetMembers, let targetHidden):
                tag = .merge
                title = appLocalizedFormat("Merge the group %1$@ into the existing group %2$@",
                    ApprovalCopy.quoted(from), ApprovalCopy.quoted(to))
                detail = ApprovalCopy.sentences([
                    appLocalizedFormat("%1$@ disappears and %2$@ will have %3$@.", ApprovalCopy.quoted(from),
                        ApprovalCopy.quoted(to), ApprovalCopy.members(members + targetMembers, hidden: hidden + targetHidden)),
                    appLocalized("A merge can't be undone automatically."),
                ])
            case .deleteGroup(let name, let members, let hidden):
                tag = nil
                title = appLocalizedFormat("Delete the group %@", ApprovalCopy.quoted(name))
                detail = members == 0
                    ? appLocalized("The group is empty.")
                    : appLocalizedFormat("Its %1$@ won't be deleted and will become %2$@.",
                        ApprovalCopy.members(members, hidden: hidden), ApprovalCopy.group(nil))
            }
            return Row(number: index + 1, tag: tag, title: title, detail: detail)
        }
        isDestructive = summary.operations.contains {
            switch $0 {
            case .deleteGroup, .mergeGroup: return true
            case .move, .createGroup, .existingGroup, .renameGroup: return false
            }
        }
    }

    private static func contents(members: Int, hidden: Int) -> String {
        members == 0
            ? appLocalized("The group is empty.")
            : appLocalizedFormat("It has %@.", ApprovalCopy.members(members, hidden: hidden))
    }
}

/// The ordered steps; the card's scrolling body counts them while any are
/// still below the visible part.
struct FrozenOrganizationApprovalContent: View {
    let content: FrozenOrganizationSummaryContent

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(content.rows, id: \.number) { row in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(verbatim: "\(row.number).")
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ApprovalLineText(line: ApprovalLine(row.title), tag: row.tag)
                            .foregroundStyle(Theme.text)
                        if let detail = row.detail {
                            Text(verbatim: detail)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .textSelection(.enabled)
                .approvalScrollMarker()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approval-organization-step-\(row.number)")
            }
        }
        .font(Theme.Fonts.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
