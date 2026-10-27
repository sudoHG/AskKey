import Foundation
import AskKeyBroker

/// Presentation only: the frozen summary remains the approval's source of truth.
struct FrozenWriteSummaryContent: Equatable {
    struct Component: Equatable {
        let name: String
        /// Set on modify only: how this item changes.
        let tag: ApprovalTag?
        let delivery: BrokerComponentDelivery
        /// Its value is new, so it can be viewed before approving.
        let carriesValue: Bool
    }

    struct GroupChange: Equatable {
        let before: String
        let after: String
        let createsGroup: Bool
    }

    let operation: BrokerApprovalOperation
    /// The line under the card's title: where a new credential goes, or what
    /// a change does. Delete says the same for every card, so it has none here.
    let subtitle: String?
    let components: [Component]
    /// Create: the instructions to save; empty when there are none.
    let instructions: String
    /// Modify: the word-level change, when the instructions change.
    let instructionsDiff: ApprovalTextDiff?
    /// Modify: the group before and after, when it changes.
    let groupChange: GroupChange?
    let valueOnlyChange: Bool
    /// A modify that overwrites or removes values that can't be recovered.
    let isDestructive: Bool
    let recoveryWarning: String?

    var valueComponents: [Component] { components.filter(\.carriesValue) }
    /// Modify: the items that change, in order; unchanged ones are left out.
    var changedComponents: [Component] { components.filter { $0.tag != nil && $0.tag != .unchanged } }

    init(summary: BrokerCredentialWriteSummary, requester: String) {
        operation = summary.operation
        let modify = summary.operation == .modify
        let components = modify
            ? Self.modifiedComponents(summary)
            : (summary.operation == .delete ? summary.before : summary.after).map {
                Component(name: $0.name, tag: nil, delivery: $0.delivery, carriesValue: summary.operation == .create)
            }
        self.components = components
        let beforeInstructions = summary.beforeUsageInstructions ?? ""
        let afterInstructions = summary.afterUsageInstructions ?? ""
        let instructionsChanged = beforeInstructions != afterInstructions
        let groupChanged = summary.beforeGroup != summary.afterGroup
        instructions = summary.operation == .create ? afterInstructions : ""
        instructionsDiff = modify && instructionsChanged
            ? ApprovalTextDiff(before: beforeInstructions, after: afterInstructions) : nil
        groupChange = modify && groupChanged
            ? GroupChange(before: ApprovalCopy.group(summary.beforeGroup), after: ApprovalCopy.group(summary.afterGroup),
                          createsGroup: summary.createsGroup)
            : nil
        let componentsChanged = modify && components.contains { $0.tag != .unchanged }
        valueOnlyChange = componentsChanged && !instructionsChanged && !groupChanged
            && components.allSatisfy { $0.tag == .unchanged || $0.tag == .replaced }
        isDestructive = modify && components.contains { $0.tag == .replaced || $0.tag == .removed }
        recoveryWarning = modify && !valueOnlyChange ? Self.recoveryWarning(components) : nil
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
                group: groupChanged)
        case .read, .delete, .organize:
            subtitle = nil
        }
    }

    /// Frozen upserts replace values even when the old value is unknown.
    private static func modifiedComponents(_ summary: BrokerCredentialWriteSummary) -> [Component] {
        let digestsEqual = summary.beforeDigest != nil && summary.beforeDigest == summary.afterDigest
        let before = Dictionary(summary.before.map { (ApprovalCopy.matchKey($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let afterNames = Set(summary.after.map { ApprovalCopy.matchKey($0.name) })
        var rows = summary.after.map { after -> Component in
            guard let old = before[ApprovalCopy.matchKey(after.name)] else {
                return Component(name: after.name, tag: .new, delivery: after.delivery, carriesValue: true)
            }
            let valueChanged: Bool
            if let changed = after.valueChanged {
                valueChanged = changed
            } else if let oldDigest = old.valueDigest, let newDigest = after.valueDigest {
                valueChanged = oldDigest != newDigest
            } else {
                // Without per-item digests, claim a replacement unless nothing changed.
                valueChanged = old.byteCount != after.byteCount || old.payloadKind != after.payloadKind || !digestsEqual
            }
            if valueChanged {
                return Component(name: after.name, tag: .replaced, delivery: after.delivery, carriesValue: true)
            }
            let settingsChanged = old.delivery != after.delivery || old.masked != after.masked || old.name != after.name
            return Component(name: after.name, tag: settingsChanged ? .changed : .unchanged, delivery: after.delivery,
                             carriesValue: false)
        }
        rows += summary.before.filter { !afterNames.contains(ApprovalCopy.matchKey($0.name)) }.map {
            Component(name: $0.name, tag: .removed, delivery: $0.delivery, carriesValue: false)
        }
        return rows
    }

    /// The short change summary; recovery and full instruction edits live in Details.
    private static func changeSubtitle(_ components: [Component], instructions: Bool,
                                       group: Bool) -> String {
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
            clauses.append(appLocalizedFormat("changes %@", ApprovalCopy.list(changes)))
        }
        if added > 0 {
            clauses.append(added == 1 ? appLocalized("adds 1 item") : appLocalizedFormat("adds %lld items", added))
        }
        if removed > 0 {
            clauses.append(removed == 1 ? appLocalized("removes 1 item") : appLocalizedFormat("removes %lld items", removed))
        }
        guard !clauses.isEmpty else { return appLocalized("Nothing changes") }
        return ApprovalCopy.capitalized(clauses.joined(separator: appLocalized("Clause separator")))
    }

    private static func recoveryWarning(_ components: [Component]) -> String? {
        let replaced = components.filter { $0.tag == .replaced }.count
        let removed = components.filter { $0.tag == .removed }.count
        switch (replaced, removed) {
        case (0, 0): return nil
        case (1, 0): return appLocalized("The old value can't be recovered")
        case (_, 0): return appLocalized("The old values can't be recovered")
        case (0, 1): return appLocalized("The removed value can't be recovered")
        case (0, _): return appLocalized("The removed values can't be recovered")
        default: return appLocalized("The old and removed values can't be recovered")
        }
    }
}
