import Foundation
import AskKeyBroker

/// Each frozen step as a sentence. Counts come from the summary, which
/// records them as they stand when that step runs.
struct FrozenOrganizationSummaryContent: Equatable {
    struct Row: Equatable {
        let number: Int
        let tag: ApprovalTag?
        let title: String
        let detail: String?
        var lastNumber: Int? = nil
    }

    let rows: [Row]
    /// A merge can't be undone automatically.
    let isDestructive: Bool
    /// Step and merge counts, followed by the hidden-credential consequence.
    let subtitle: String

    init(summary: BrokerOrganizationSummary, requester: String) {
        let steps = summary.operations.enumerated().map { index, operation in
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
                    appLocalized("Already exists; nothing changes."),
                    Self.contents(members: members, hidden: hidden),
                ])
            case .renameGroup(let from, let to, let members, let hidden):
                tag = nil
                title = appLocalizedFormat("Rename the group %1$@ to %2$@", ApprovalCopy.quoted(from), ApprovalCopy.quoted(to))
                detail = Self.contents(members: members, hidden: hidden)
            case .mergeGroup(let from, let to, let members, let hidden, let targetMembers, let targetHidden):
                // The requester asked for a rename; the target exists but is
                // hidden from it, so the batch merges the two groups.
                tag = .merge
                title = appLocalizedFormat("Merge the group %1$@ into %2$@", ApprovalCopy.quoted(from), ApprovalCopy.quoted(to))
                detail = appLocalizedFormat("%1$@ requested a rename, but can’t see the existing group. The merged group will have %2$@. This can’t be undone.",
                    requester, ApprovalCopy.members(members + targetMembers, hidden: hidden + targetHidden))
            case .deleteGroup(let name, let members, let hidden):
                tag = nil
                title = appLocalizedFormat("Delete the group %@", ApprovalCopy.quoted(name))
                let hiddenNote = hidden > 0
                    ? appLocalizedFormat("Approval hidden count suffix", appLocalizedFormat("%lld hidden from agents", hidden)) : ""
                detail = members == 0 ? appLocalized("The group is empty.")
                    : appLocalizedFormat("Move %1$@ to %2$@; nothing is deleted%3$@.",
                        ApprovalCopy.members(members, hidden: 0), ApprovalCopy.group(nil), hiddenNote)
            }
            return Row(number: index + 1, tag: tag, title: title, detail: detail)
        }
        rows = Self.summarized(steps, operations: summary.operations)
        let merges = summary.operations.filter {
            if case .mergeGroup = $0 { return true } else { return false }
        }.count
        isDestructive = merges > 0
        let count = summary.operations.count
        var subtitle = count == 1 ? appLocalized("1 step") : appLocalizedFormat("%lld steps", count)
        if merges == 1 {
            subtitle = appLocalizedFormat("%@ · 1 merge", subtitle)
        } else if merges > 1 {
            subtitle = appLocalizedFormat("%1$@ · %2$lld merges", subtitle, merges)
        }
        let hidden = Self.hiddenCredentials(summary)
        if hidden == 1 {
            subtitle = appLocalizedFormat("%@ · affects 1 hidden credential", subtitle)
        } else if hidden > 1 {
            subtitle = appLocalizedFormat("%1$@ · affects %2$lld hidden credentials", subtitle, hidden)
        }
        if rows.count == 1, rows[0].lastNumber != nil, let first = summary.operations.first,
           case .move(_, _, let destination) = first {
            subtitle = appLocalizedFormat("Move %1$lld credentials to %2$@", count, ApprovalCopy.group(destination))
        }
        self.subtitle = subtitle
    }

    /// Only consecutive moves with exactly the same endpoints can share a row.
    /// Never reorder operations or fold away merges, renames or deletions.
    private static func summarized(_ rows: [Row], operations: [BrokerOrganizationSummary.Operation]) -> [Row] {
        var result: [Row] = []
        var index = 0
        while index < operations.count {
            guard case .move(let name, let from, let to) = operations[index] else {
                result.append(rows[index]); index += 1; continue
            }
            var names = [name]
            var end = index + 1
            while end < operations.count,
                  case .move(let next, let nextFrom, let nextTo) = operations[end], nextFrom == from, nextTo == to {
                names.append(next)
                end += 1
            }
            if names.count >= 3 {
                result.append(Row(number: index + 1, tag: nil,
                    title: appLocalizedFormat("Move %1$lld credentials from %2$@ to %3$@", names.count,
                        ApprovalCopy.group(from), ApprovalCopy.group(to)),
                    detail: names.map(ApprovalCopy.quoted).joined(separator: appLocalized("List separator")), lastNumber: end))
            } else {
                result += rows[index..<end]
            }
            index = end
        }
        return result
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
        return members == 0
            ? appLocalized("The group is empty.")
            : appLocalizedFormat("It has %@.", ApprovalCopy.members(members, hidden: hidden))
    }
}
