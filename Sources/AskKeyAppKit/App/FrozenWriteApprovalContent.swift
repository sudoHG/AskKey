import SwiftUI
import AskKeyBroker

/// A write card's Details: the items with their status tags, the
/// instructions and group, what approving does, and the separately
/// authenticated value view.
struct FrozenWriteApprovalContent: View {
    let operation: BrokerApprovalOperation
    var content: FrozenWriteSummaryContent?
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)?
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let content {
                if !content.components.isEmpty { items(content) }
                instructions(content)
                group(content)
                if let consequence = content.consequence {
                    ApprovalSection(title: appLocalized("After you approve"), identifier: "approval-consequence") {
                        Text(verbatim: consequence).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if operation == .create || operation == .modify {
                // Without the summary the value can still be viewed before deciding.
                ApprovalSection(title: appLocalized("Items"), identifier: "approval-components",
                                accessory: { revealButton }) { valueDetails }
            }
        }
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    private func items(_ content: FrozenWriteSummaryContent) -> some View {
        let hasValues = !content.valueComponents.isEmpty
        return ApprovalSection(title: content.itemsHeading, identifier: "approval-components",
                               accessory: { if hasValues { revealButton } }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(content.components.enumerated()), id: \.offset) { _, component in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        VStack(alignment: .leading, spacing: 2) {
                            ApprovalLineText(line: component.line, tag: component.tag)
                            ForEach(Array(component.notes.enumerated()), id: \.offset) { _, note in
                                ApprovalLineText(line: note)
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            if component.overwrites {
                                Text(appLocalized("If you approve, the old value is overwritten and can't be recovered."))
                                    .font(Theme.Fonts.caption)
                                    .foregroundStyle(Theme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if component.carriesValue {
                            Text(verbatim: "••••••").foregroundStyle(Theme.textSecondary).fixedSize()
                                .accessibilityLabel(Text(appLocalized("Hidden value")))
                        }
                    }
                }
                if hasValues { valueDetails }
            }
        }
    }

    @ViewBuilder
    private var revealButton: some View {
        if revealedMaterial != nil {
            Button(appLocalized("Hide")) { revealedMaterial = nil }
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.accent)
                .fixedSize()
        } else {
            Button(appLocalized("Authenticate to View"), action: reveal)
                .buttonStyle(.plain)
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.accent)
                .fixedSize()
                .disabled(revealMaterial == nil || revealing)
                .accessibilityIdentifier("approval-reveal-frozen-material")
        }
    }

    @ViewBuilder
    private var valueDetails: some View {
        if let revealedMaterial {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(revealedMaterial.title).lineLimit(1)
                    Spacer()
                    Text(revealedMaterial.encoding).foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.Fonts.caption)
                ApprovalScrollArea(space: "approval-revealed-value", maxHeight: 85,
                                   indicatorOffset: Theme.Spacing.sm - 2) {
                    Text(verbatim: revealedMaterial.content)
                        .font(Theme.Fonts.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Spacing.sm)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
            .accessibilityIdentifier("approval-revealed-value")
        } else {
            Text(appLocalized("Saved as is if you approve. Viewing needs another authentication; it doesn't approve."))
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if revealFailed {
            Text(appLocalized("Unable to view: authentication was not completed or the request is no longer valid."))
                .font(Theme.Fonts.caption).foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func instructions(_ content: FrozenWriteSummaryContent) -> some View {
        switch content.instructions {
        case .unchanged:
            EmptyView()
        case .current(let text):
            ApprovalSection(title: appLocalized("Instructions for agents"), identifier: "approval-usage-instructions") {
                Text(verbatim: text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .changed(let before, let after):
            ApprovalSection(title: appLocalized("Instructions for agents"), tag: content.instructionsTag,
                            identifier: "approval-usage-instructions") {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    comparison(before: diffText(content.instructionsDiff?.before, placeholder: before),
                               after: diffText(content.instructionsDiff?.after, placeholder: after))
                    if let removed = content.instructionsDiff?.removedPhrases, !removed.isEmpty {
                        Text(appLocalizedFormat("Removed phrases: %@",
                            removed.map(ApprovalCopy.quoted).joined(separator: appLocalized("List separator"))))
                            .font(Theme.Fonts.caption)
                            .foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("approval-instructions-removed")
                    }
                }
            }
        }
    }

    /// Removed words in red with a line through them, added words in green.
    private func diffText(_ runs: [ApprovalTextDiff.Run]?, placeholder: String) -> Text {
        guard let runs, !runs.isEmpty else { return Text(verbatim: placeholder) }
        return Text(runs.reduce(into: AttributedString()) { result, run in
            var part = AttributedString(run.text)
            switch run.kind {
            case .same: break
            case .removed:
                part.foregroundColor = Theme.warning
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = ApprovalTag.new.color
            }
            result += part
        })
    }

    @ViewBuilder
    private func group(_ content: FrozenWriteSummaryContent) -> some View {
        switch content.group {
        case .unchanged:
            EmptyView()
        case .current(let name):
            ApprovalSection(title: appLocalized("Group"), identifier: "approval-group-changes") {
                groupName(name, createsGroup: content.createsGroup)
            }
        case .changed(let before, let after):
            ApprovalSection(title: appLocalized("Group"), tag: content.groupTag, identifier: "approval-group-changes") {
                comparison(before: Text(verbatim: before), after: groupName(after, createsGroup: content.createsGroup))
            }
        }
    }

    private func groupName(_ name: String, createsGroup: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if createsGroup {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    ApprovalTagView(tag: .newGroup)
                    Text(appLocalized("Created when you approve"))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approval-new-group")
            }
        }
    }

    private func comparison(before: some View, after: some View) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
            GridRow {
                Text(appLocalized("Before")).foregroundStyle(Theme.textSecondary).fixedSize()
                before.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Text(appLocalized("After")).foregroundStyle(Theme.textSecondary).fixedSize()
                after.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func reveal() {
        guard let revealMaterial, !revealing else { return }
        revealing = true
        revealFailed = false
        revealTask = Task {
            defer { revealing = false }
            do {
                let material = try await revealMaterial()
                guard !Task.isCancelled else { return }
                revealedMaterial = material
            } catch {
                if !Task.isCancelled { revealFailed = true }
            }
        }
    }
}
