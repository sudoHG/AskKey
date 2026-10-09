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
    /// A merge can't be undone automatically.
    let isDestructive: Bool
    /// "6 steps, one of which merges groups, affecting 3 hidden credentials".
    let subtitle: String

    init(summary: BrokerOrganizationSummary, requester: String) {
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
                detail = members == 0
                    ? appLocalized("When it's renamed, the group is empty.")
                    : appLocalizedFormat("When it's renamed, the group has %@.", ApprovalCopy.members(members, hidden: hidden))
            case .mergeGroup(let from, let to, let members, let hidden, let targetMembers, let targetHidden):
                // The requester asked for a rename; the target exists but is
                // hidden from it, so the batch merges the two groups.
                tag = .merge
                title = appLocalizedFormat("%1$@ asked to rename %2$@ to %3$@; %3$@ already exists and is hidden from it, so the groups merge.",
                    requester, ApprovalCopy.quoted(from), ApprovalCopy.quoted(to))
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
        let merges = summary.operations.filter {
            if case .mergeGroup = $0 { return true } else { return false }
        }.count
        isDestructive = merges > 0
        var subtitle = rows.count == 1 ? appLocalized("1 step") : appLocalizedFormat("%lld steps", rows.count)
        if merges == 1 {
            subtitle = appLocalizedFormat("%@, one of which merges groups", subtitle)
        } else if merges > 1 {
            subtitle = appLocalizedFormat("%1$@, %2$lld of which merge groups", subtitle, merges)
        }
        let hidden = Self.hiddenCredentials(summary)
        if hidden == 1 {
            subtitle = appLocalizedFormat("%@, affecting 1 hidden credential", subtitle)
        } else if hidden > 1 {
            subtitle = appLocalizedFormat("%1$@, affecting %2$lld hidden credentials", subtitle, hidden)
        }
        self.subtitle = subtitle
    }

    /// Hidden credentials whose group the batch renames, merges away or
    /// deletes. Each step's counts include credentials an earlier step already
    /// moved into that group, so those are counted once.
    static func hiddenCredentials(_ summary: BrokerOrganizationSummary) -> Int {
        var counted: [String: Int] = [:]
        var total = 0
        func leave(_ group: String, hidden: Int) -> Int {
            let key = ApprovalCopy.matchKey(group)
            defer { counted[key] = nil }
            return max(0, hidden - counted[key, default: 0])
        }
        for operation in summary.operations {
            switch operation {
            case .renameGroup(let from, let to, _, let hidden):
                total += leave(from, hidden: hidden)
                counted[ApprovalCopy.matchKey(to)] = hidden
            case .mergeGroup(let from, let to, _, let hidden, _, _):
                total += leave(from, hidden: hidden)
                counted[ApprovalCopy.matchKey(to), default: 0] += hidden
            case .deleteGroup(let name, _, let hidden):
                total += leave(name, hidden: hidden)
            case .move, .createGroup, .existingGroup:
                break
            }
        }
        return total
    }

    private static func contents(members: Int, hidden: Int) -> String {
        members == 0
            ? appLocalized("The group is empty.")
            : appLocalizedFormat("It has %@.", ApprovalCopy.members(members, hidden: hidden))
    }
}

/// The ordered steps, shown in Details.
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
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approval-organization-step-\(row.number)")
            }
        }
        .font(Theme.Fonts.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
