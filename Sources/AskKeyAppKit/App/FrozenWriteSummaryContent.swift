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
        /// Listed in the value box: its value is new or may have been replaced.
        let carriesValue: Bool
        let byteCount: Int
    }

    enum Change: Equatable {
        /// Create and delete show the one value involved.
        case current(String)
        case changed(before: String, after: String)
        /// Modify: folded into the change summary line.
        case unchanged
    }

    let operation: BrokerApprovalOperation
    /// Modify only: "Changes: … · Unchanged: …".
    let changeSummary: String?
    /// Empty when a modify leaves every item as it was.
    let components: [Component]
    let itemCount: Int
    let componentsTag: ApprovalTag?
    let overwritesValues: Bool
    let instructions: Change
    let instructionsTag: ApprovalTag?
    let group: Change
    let groupTag: ApprovalTag?
    let createsGroup: Bool
    let afterApproval: String?
    let valueOnlyChange: Bool
    let valueHeading: String

    var valueComponents: [Component] { components.filter(\.carriesValue) }

    init(summary: BrokerCredentialWriteSummary, requester: String) {
        operation = summary.operation
        let modify = summary.operation == .modify
        let components = modify
            ? Self.modifiedComponents(summary, requester: requester)
            : (summary.operation == .delete ? summary.before : summary.after).map {
                Component(name: $0.name, tag: nil, line: Self.line($0), notes: [],
                    carriesValue: summary.operation == .create, byteCount: $0.byteCount)
            }
        let componentsChanged = !modify || components.contains { $0.tag != .unchanged }
        self.components = componentsChanged ? components : []
        itemCount = (summary.operation == .delete ? summary.before : summary.after).count
        componentsTag = modify && componentsChanged ? .changed : nil
        overwritesValues = components.contains { [.replaced, .mayBeReplaced, .changed].contains($0.tag) }

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
        groupTag = modify && groupChanged ? .changed : nil
        createsGroup = summary.createsGroup && (summary.operation == .create || summary.operation == .modify)
        changeSummary = modify ? Self.changeSummary(items: componentsChanged,
            instructions: instructionsChanged, group: groupChanged) : nil
        valueOnlyChange = modify && componentsChanged && !instructionsChanged && !groupChanged
            && components.allSatisfy { [.unchanged, .replaced, .mayBeReplaced].contains($0.tag) }
        switch summary.operation {
        case .create:
            afterApproval = appLocalized("The credential's agent permission will be Ask every time: agents need your approval each time they use it.")
        case .delete:
            afterApproval = appLocalized("It moves to the Recycle Bin for 30 days and can be restored there, then it is removed permanently. Agents can't use or see it meanwhile.")
        case .read, .modify, .organize:
            afterApproval = nil
        }
        valueHeading = summary.operation == .create
            ? appLocalizedFormat("Value to save (provided by %@)", requester)
            : appLocalizedFormat("New value (provided by %@)", requester)
    }

    /// The summary carries one digest over all items, so a same-size item can
    /// be proven unchanged or replaced only when nothing else differs.
    private static func modifiedComponents(_ summary: BrokerCredentialWriteSummary,
        requester: String) -> [Component] {
        let digestsEqual = summary.beforeDigest != nil && summary.beforeDigest == summary.afterDigest
        let soleReplacement = !digestsEqual && summary.beforeDigest != nil && summary.afterDigest != nil
            && summary.before == summary.after && summary.after.count == 1
        let before = Dictionary(summary.before.map { (normalized($0.name), $0) }, uniquingKeysWith: { first, _ in first })
        let afterNames = Set(summary.after.map { normalized($0.name) })
        var rows = summary.after.map { after -> Component in
            guard let old = before[normalized(after.name)] else {
                return Component(name: after.name, tag: .new, line: line(after), notes: [],
                    carriesValue: true, byteCount: after.byteCount)
            }
            if old.byteCount != after.byteCount || old.payloadKind != after.payloadKind {
                var notes = [ApprovalLine(appLocalizedFormat("old value %1$@ → new value %2$@ (new value from %3$@)",
                    ApprovalCopy.bytes(old.byteCount), ApprovalCopy.bytes(after.byteCount), requester))]
                if old.delivery != after.delivery {
                    notes.append(previous(ApprovalCopy.delivery(old.delivery)))
                }
                return Component(name: after.name, tag: .replaced,
                    line: ApprovalLine(after.name + " · ") + ApprovalCopy.delivery(after.delivery),
                    notes: notes, carriesValue: true, byteCount: after.byteCount)
            }
            if old.delivery != after.delivery || old.masked != after.masked || old.name != after.name {
                var notes = [previous(line(old))]
                if old.masked != after.masked {
                    notes.append(ApprovalLine(after.masked
                        ? appLocalized("Now masked when shown in Ask Key")
                        : appLocalized("Now shown in full in Ask Key")))
                }
                notes.append(ApprovalLine(appLocalized("Same size; Ask Key can't tell whether the value was replaced. Authenticate to view.")))
                return Component(name: after.name, tag: .changed, line: line(after), notes: notes,
                    carriesValue: true, byteCount: after.byteCount)
            }
            if digestsEqual {
                return Component(name: after.name, tag: .unchanged, line: line(after), notes: [],
                    carriesValue: false, byteCount: after.byteCount)
            }
            if soleReplacement {
                return Component(name: after.name, tag: .replaced,
                    line: ApprovalLine(after.name + " · ") + ApprovalCopy.delivery(after.delivery),
                    notes: [ApprovalLine(appLocalizedFormat("old value %1$@ → new value %2$@ (new value from %3$@)",
                        ApprovalCopy.bytes(old.byteCount), ApprovalCopy.bytes(after.byteCount), requester))],
                    carriesValue: true, byteCount: after.byteCount)
            }
            return Component(name: after.name, tag: .mayBeReplaced, line: line(after),
                notes: [ApprovalLine(appLocalized("Same size and delivery; Ask Key can't tell whether the value was replaced. Authenticate to view."))],
                carriesValue: true, byteCount: after.byteCount)
        }
        rows += summary.before.filter { !afterNames.contains(normalized($0.name)) }.map {
            Component(name: $0.name, tag: .removed, line: line($0), notes: [], carriesValue: false, byteCount: $0.byteCount)
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

    private static func changeSummary(items: Bool, instructions: Bool, group: Bool) -> String {
        let sections = [(appLocalized("items"), items), (appLocalized("instructions"), instructions),
                        (appLocalized("group"), group)]
        let separator = appLocalized("List separator")
        let changed = sections.filter(\.1).map(\.0).joined(separator: separator)
        let unchanged = sections.filter { !$0.1 }.map(\.0).joined(separator: separator)
        if changed.isEmpty { return appLocalized("Nothing changes") }
        if unchanged.isEmpty { return appLocalizedFormat("Changes: %@", changed) }
        return appLocalizedFormat("Changes: %1$@ · Unchanged: %2$@", changed, unchanged)
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
