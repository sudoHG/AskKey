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
    }

    enum Change: Equatable {
        /// Create and delete show the one value involved.
        case current(String)
        case changed(before: String, after: String)
        /// Modify: left out of Details.
        case unchanged
    }

    let operation: BrokerApprovalOperation
    /// The line under the card's title: where a new credential goes, or what
    /// a change does. Delete says the same for every card, so it has none here.
    let subtitle: String?
    let components: [Component]
    let itemCount: Int
    let itemsHeading: String
    let instructions: Change
    let instructionsTag: ApprovalTag?
    let instructionsDiff: ApprovalTextDiff?
    let group: Change
    let groupTag: ApprovalTag?
    let createsGroup: Bool
    /// What approving does, stated in Details.
    let consequence: String?
    let valueOnlyChange: Bool
    /// A modify that overwrites or removes values that can't be recovered.
    let isDestructive: Bool

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
        self.components = components
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
        valueOnlyChange = modify && componentsChanged && !instructionsChanged && !groupChanged
            && components.allSatisfy { $0.tag == .unchanged || $0.tag == .replaced }
        isDestructive = modify && components.contains { $0.tag == .replaced || $0.tag == .removed }
        switch summary.operation {
        case .create:
            subtitle = summary.afterGroup.map { group in
                summary.createsGroup
                    ? appLocalizedFormat("In the new group %@", ApprovalCopy.quoted(group))
                    : appLocalizedFormat("In the group %@", ApprovalCopy.quoted(group))
            }
        case .modify where valueOnlyChange:
            subtitle = components.filter { $0.tag == .replaced }.count == 1
                ? appLocalized("The old value can't be recovered")
                : appLocalized("The old values can't be recovered")
        case .modify:
            subtitle = Self.changeSubtitle(components, instructions: instructionsChanged,
                instructionsTextRemoved: instructionsDiff?.removedPhrases.isEmpty == false, group: groupChanged)
        case .read, .delete, .organize:
            subtitle = nil
        }
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
        let before = Dictionary(summary.before.map { (ApprovalCopy.matchKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let afterNames = Set(summary.after.map { ApprovalCopy.matchKey($0.name) })
        var rows = summary.after.map { after -> Component in
            guard let old = before[ApprovalCopy.matchKey(after.name)] else {
                return Component(name: after.name, tag: .new, line: line(after), notes: [],
                    carriesValue: true, overwrites: false, byteCount: after.byteCount)
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
                    notes: notes, carriesValue: true, overwrites: true, byteCount: after.byteCount)
            }
            if old.delivery != after.delivery || old.masked != after.masked || old.name != after.name {
                var notes = [previous(line(old))]
                if old.masked != after.masked {
                    notes.append(ApprovalLine(after.masked
                        ? appLocalized("Now masked when shown in Ask Key")
                        : appLocalized("Now shown in full in Ask Key")))
                }
                return Component(name: after.name, tag: .changed, line: line(after), notes: notes,
                    carriesValue: false, overwrites: false, byteCount: after.byteCount)
            }
            return Component(name: after.name, tag: .unchanged, line: line(after), notes: [],
                carriesValue: false, overwrites: false, byteCount: after.byteCount)
        }
        rows += summary.before.filter { !afterNames.contains(ApprovalCopy.matchKey($0.name)) }.map {
            Component(name: $0.name, tag: .removed, line: line($0), notes: [], carriesValue: false,
                overwrites: false, byteCount: $0.byteCount)
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

    /// What a change does, in the order replace, change, add, remove, then
    /// which values are lost: "Replaces 1 value, changes the group; the old
    /// value can't be recovered".
    private static func changeSubtitle(_ components: [Component], instructions: Bool,
                                       instructionsTextRemoved: Bool, group: Bool) -> String {
        func count(_ tag: ApprovalTag) -> Int { components.filter { $0.tag == tag }.count }
        let replaced = count(.replaced), changed = count(.changed), added = count(.new), removed = count(.removed)
        var clauses: [String] = []
        if replaced > 0 {
            clauses.append(replaced == 1 ? appLocalized("replaces 1 value") : appLocalizedFormat("replaces %lld values", replaced))
        }
        if changed > 0 {
            clauses.append(changed == 1
                ? appLocalized("changes the settings of 1 item") : appLocalizedFormat("changes the settings of %lld items", changed))
        }
        var changes: [String] = []
        if instructions { changes.append(appLocalized("the instructions")) }
        if group { changes.append(appLocalized("the group")) }
        if !changes.isEmpty {
            let clause = appLocalizedFormat("changes %@", ApprovalCopy.list(changes))
            clauses.append(instructionsTextRemoved
                ? appLocalizedFormat("%@ (some instruction text is deleted)", clause) : clause)
        }
        if added > 0 {
            clauses.append(added == 1 ? appLocalized("adds 1 item") : appLocalizedFormat("adds %lld items", added))
        }
        if removed > 0 {
            clauses.append(removed == 1 ? appLocalized("removes 1 item") : appLocalizedFormat("removes %lld items", removed))
        }
        guard !clauses.isEmpty else { return appLocalized("Nothing changes") }
        let text = clauses.joined(separator: appLocalized("Clause separator"))
        let lost: String
        switch (replaced, removed) {
        case (0, 0): lost = text
        case (1, 0): lost = appLocalizedFormat("%@; the old value can't be recovered", text)
        case (_, 0): lost = appLocalizedFormat("%@; the old values can't be recovered", text)
        case (0, 1): lost = appLocalizedFormat("%@; the removed value can't be recovered", text)
        case (0, _): lost = appLocalizedFormat("%@; the removed values can't be recovered", text)
        default: lost = appLocalizedFormat("%@; the old and removed values can't be recovered", text)
        }
        return ApprovalCopy.capitalized(lost)
    }

    private static func instructionsText(_ value: String) -> String {
        value.isEmpty ? appLocalized("None") : value
    }

    private static func groupText(_ name: String?) -> String {
        name.map(ApprovalCopy.quoted) ?? appLocalized("Ungrouped")
    }
}
