import Foundation
import AskKeyBroker

/// Presentation only: the frozen summary remains the approval's source of truth.
struct FrozenWriteSummaryContent: Equatable {
    struct Component: Equatable {
        let name: String
        /// Set on modify only; create and delete show plain rows.
        let tag: ApprovalTag?
        let line: ApprovalLine
        let notes: [ApprovalLine]
        /// Its value is new: the row shows masked dots and can be viewed.
        let carriesValue: Bool
        /// A replaced value: the row warns that the old one is overwritten.
        let overwrites: Bool
        let byteCount: Int
        /// How the change summary names this item's change; nil when unchanged.
        var change: String? = nil
    }

    enum Change: Equatable {
        /// Create and delete show the one value involved.
        case current(String)
        case changed(before: String, after: String)
        /// Modify: folded into the change summary line.
        case unchanged
    }

    let operation: BrokerApprovalOperation
    /// Modify only: "Changes: the value of TOKEN · Unchanged: …".
    let changeSummary: String?
    /// Empty when a modify leaves every item as it was.
    let components: [Component]
    let itemCount: Int
    let itemsHeading: String
    let instructions: Change
    let instructionsTag: ApprovalTag?
    let instructionsDiff: ApprovalTextDiff?
    let group: Change
    let groupTag: ApprovalTag?
    let createsGroup: Bool
    /// What approving does, stated under the primary button.
    let consequence: String?
    let valueOnlyChange: Bool

    var valueComponents: [Component] { components.filter(\.carriesValue) }

    init(summary: BrokerCredentialWriteSummary, requester: String) {
        operation = summary.operation
        let modify = summary.operation == .modify
        let components = modify
            ? Self.modifiedComponents(summary, requester: requester)
            : (summary.operation == .delete ? summary.before : summary.after).map {
                Component(name: $0.name, tag: nil, line: Self.line($0), notes: [],
                    carriesValue: summary.operation == .create, overwrites: false, byteCount: $0.byteCount)
            }
        let componentsChanged = !modify || components.contains { $0.tag != .unchanged }
        self.components = componentsChanged ? components : []
        itemCount = (summary.operation == .delete ? summary.before : summary.after).count
        switch summary.operation {
        case .create:
            itemsHeading = appLocalizedFormat("Items (%1$lld, values provided by %2$@)", itemCount, requester)
        case .modify where components.contains(where: \.carriesValue):
            itemsHeading = appLocalizedFormat("Items (%1$lld, new values provided by %2$@)", itemCount, requester)
        case .read, .modify, .delete, .organize:
            itemsHeading = appLocalizedFormat("Items (%lld)", itemCount)
        }

        let beforeInstructions = summary.beforeUsageInstructions ?? ""
        let afterInstructions = summary.afterUsageInstructions ?? ""
        let instructionsChanged = beforeInstructions != afterInstructions
        let groupChanged = summary.beforeGroup != summary.afterGroup
        switch summary.operation {
        case .modify:
            instructions = instructionsChanged
                ? .changed(before: Self.instructionsText(beforeInstructions), after: Self.instructionsText(afterInstructions))
                : .unchanged
            group = groupChanged
                ? .changed(before: Self.groupText(summary.beforeGroup), after: Self.groupText(summary.afterGroup))
                : .unchanged
        case .delete, .read, .organize:
            instructions = .current(Self.instructionsText(beforeInstructions))
            group = .current(Self.groupText(summary.beforeGroup))
        case .create:
            instructions = .current(Self.instructionsText(afterInstructions))
            group = .current(Self.groupText(summary.afterGroup))
        }
        instructionsTag = modify && instructionsChanged ? .changed : nil
        instructionsDiff = modify && instructionsChanged
            ? ApprovalTextDiff(before: beforeInstructions, after: afterInstructions) : nil
        groupTag = modify && groupChanged ? .changed : nil
        createsGroup = summary.createsGroup && (summary.operation == .create || summary.operation == .modify)
        changeSummary = modify ? Self.changeSummary(components, instructions: instructionsChanged, group: groupChanged) : nil
        valueOnlyChange = modify && componentsChanged && !instructionsChanged && !groupChanged
            && components.allSatisfy { $0.tag == .unchanged || $0.tag == .replaced }
        switch summary.operation {
        case .create:
            consequence = appLocalized("Its agent permission will be Ask every time, so agents need your approval for each use.")
        case .delete:
            consequence = appLocalized("It moves to the Recycle Bin for 30 days and can be restored there, then it is removed permanently. Agents can't use or see it meanwhile.")
        case .read, .modify, .organize:
            consequence = nil
        }
    }

    /// Each item is matched by name and tagged from its own value digest.
    private static func modifiedComponents(_ summary: BrokerCredentialWriteSummary,
        requester: String) -> [Component] {
        let digestsEqual = summary.beforeDigest != nil && summary.beforeDigest == summary.afterDigest
        let before = Dictionary(summary.before.map { (normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let afterNames = Set(summary.after.map { normalized($0.name) })
        var rows = summary.after.map { after -> Component in
            guard let old = before[normalized(after.name)] else {
                return Component(name: after.name, tag: .new, line: line(after), notes: [],
                    carriesValue: true, overwrites: false, byteCount: after.byteCount,
                    change: appLocalizedFormat("%@ added", after.name))
            }
            let valueChanged: Bool
            if let oldDigest = old.valueDigest, let newDigest = after.valueDigest {
                valueChanged = oldDigest != newDigest
            } else {
                // Without per-item digests, claim a replacement unless nothing changed.
                valueChanged = old.byteCount != after.byteCount || old.payloadKind != after.payloadKind || !digestsEqual
            }
            if valueChanged {
                var notes = [ApprovalLine(appLocalizedFormat("Old value %1$@ → new value %2$@ (new value from %3$@)",
                    ApprovalCopy.bytes(old.byteCount), ApprovalCopy.bytes(after.byteCount), requester))]
                if old.delivery != after.delivery {
                    notes.append(previous(ApprovalCopy.delivery(old.delivery)))
                }
                return Component(name: after.name, tag: .replaced,
                    line: ApprovalLine(after.name + " · ") + ApprovalCopy.delivery(after.delivery),
                    notes: notes, carriesValue: true, overwrites: true, byteCount: after.byteCount,
                    change: appLocalizedFormat("the value of %@", after.name))
            }
            if old.delivery != after.delivery || old.masked != after.masked || old.name != after.name {
                var notes = [previous(line(old))]
                if old.masked != after.masked {
                    notes.append(ApprovalLine(after.masked
                        ? appLocalized("Now masked when shown in Ask Key")
                        : appLocalized("Now shown in full in Ask Key")))
                }
                return Component(name: after.name, tag: .changed, line: line(after), notes: notes,
                    carriesValue: false, overwrites: false, byteCount: after.byteCount,
                    change: old.delivery != after.delivery
                        ? appLocalizedFormat("how %@ is given to programs", after.name)
                        : appLocalizedFormat("the settings of %@", after.name))
            }
            return Component(name: after.name, tag: .unchanged, line: line(after), notes: [],
                carriesValue: false, overwrites: false, byteCount: after.byteCount)
        }
        rows += summary.before.filter { !afterNames.contains(normalized($0.name)) }.map {
            Component(name: $0.name, tag: .removed, line: line($0), notes: [], carriesValue: false,
                overwrites: false, byteCount: $0.byteCount, change: appLocalizedFormat("%@ removed", $0.name))
        }
        return rows
    }

    /// "{name} · {N} bytes · {delivery in plain words}".
    static func line(_ item: BrokerCredentialComponentSummary) -> ApprovalLine {
        ApprovalLine(item.name + " · " + ApprovalCopy.bytes(item.byteCount) + " · ") + ApprovalCopy.delivery(item.delivery)
    }

    private static func previous(_ line: ApprovalLine) -> ApprovalLine {
        let parts = appLocalized("Before: %@").components(separatedBy: "%@")
        return ApprovalLine(parts.first ?? "") + line + ApprovalLine(parts.dropFirst().joined())
    }

    /// Names what changes and what stays, item by item; never a section name
    /// standing in for the items.
    private static func changeSummary(_ components: [Component], instructions: Bool, group: Bool) -> String {
        var changed = components.compactMap(\.change)
        var unchanged = components.filter { $0.change == nil }.map(\.name)
        let instructionsName = appLocalized("Change summary: instructions")
        let groupName = appLocalized("group")
        if instructions { changed.append(instructionsName) } else { unchanged.append(instructionsName) }
        if group { changed.append(groupName) } else { unchanged.append(groupName) }
        let separator = appLocalized("List separator")
        if changed.isEmpty { return appLocalized("Nothing changes") }
        if unchanged.isEmpty { return appLocalizedFormat("Changes: %@", changed.joined(separator: separator)) }
        return appLocalizedFormat("Changes: %1$@ · Unchanged: %2$@",
            changed.joined(separator: separator), unchanged.joined(separator: separator))
    }

    private static func instructionsText(_ value: String) -> String {
        value.isEmpty ? appLocalized("None") : value
    }

    private static func groupText(_ name: String?) -> String {
        name.map(ApprovalCopy.quoted) ?? appLocalized("Ungrouped")
    }

    private static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
