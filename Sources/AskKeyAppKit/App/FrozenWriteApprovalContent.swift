import SwiftUI
import AskKeyBroker

/// The write card's fixed sections and the separately authenticated value view.
struct FrozenWriteApprovalContent: View {
    let operation: BrokerApprovalOperation
    var content: FrozenWriteSummaryContent?
    var requester: String
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)?
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if let content {
                if let summary = content.changeSummary {
                    Text(verbatim: summary)
                        .font(Theme.Fonts.secondary)
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .approvalScrollMarker()
                        .accessibilityIdentifier("approval-change-summary")
                }
                if !content.components.isEmpty { items(content) }
                if !content.valueComponents.isEmpty {
                    valueBox(heading: content.valueHeading, components: content.valueComponents)
                }
                instructions(content)
                group(content)
                if let after = content.afterApproval {
                    ApprovalSection(title: appLocalized("After you approve"), identifier: "approval-after-approval") {
                        Text(verbatim: after).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if operation == .create || operation == .modify {
                valueBox(heading: appLocalizedFormat("New value (provided by %@)", requester), components: [])
            }
        }
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    private func items(_ content: FrozenWriteSummaryContent) -> some View {
        ApprovalSection(title: appLocalizedFormat("Items (%lld)", content.itemCount), tag: content.componentsTag,
                        identifier: "approval-components") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(Array(content.components.enumerated()), id: \.offset) { _, component in
                    VStack(alignment: .leading, spacing: 2) {
                        ApprovalLineText(line: component.line, tag: component.tag)
                        ForEach(Array(component.notes.enumerated()), id: \.offset) { _, note in
                            ApprovalLineText(line: note)
                                .font(Theme.Fonts.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                if content.overwritesValues {
                    Text(appLocalized("A replaced value overwrites the old one. There is no history."))
                        .font(Theme.Fonts.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
                comparison(before: Text(verbatim: before), after: Text(verbatim: after))
            }
        }
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
                    Text(appLocalized("created when you approve"))
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

    private func valueBox(heading: String, components: [FrozenWriteSummaryContent.Component]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(verbatim: heading)
                .font(Theme.Fonts.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let revealedMaterial {
                HStack {
                    Text(revealedMaterial.title).lineLimit(1)
                    Spacer()
                    Text(revealedMaterial.encoding).foregroundStyle(Theme.textSecondary)
                    Button(appLocalized("Hide")) { self.revealedMaterial = nil }
                }.font(Theme.Fonts.caption)
                ApprovalScrollArea(space: "approval-revealed-value", unit: .lines(height: 15), maxHeight: 85,
                                   indicatorOffset: Theme.Spacing.sm) { _ in
                    Text(verbatim: revealedMaterial.content)
                        .font(Theme.Fonts.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        Text(verbatim: component.name).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: ApprovalCopy.bytes(component.byteCount)).foregroundStyle(Theme.textSecondary).fixedSize()
                        Spacer(minLength: Theme.Spacing.xs)
                        Text(verbatim: "••••••••").foregroundStyle(Theme.textSecondary).fixedSize()
                    }
                }
                Button(appLocalized("Authenticate to View"), action: reveal)
                    .disabled(revealMaterial == nil || revealing)
                    .accessibilityIdentifier("approval-reveal-frozen-material")
                Text(appLocalized("This is the value saved if you approve. Viewing needs another authentication and does not approve the request."))
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
        .font(Theme.Fonts.secondary)
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.group))
        .approvalScrollMarker()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval-value-box")
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
