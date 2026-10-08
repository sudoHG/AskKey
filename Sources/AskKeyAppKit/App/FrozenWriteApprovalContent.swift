import SwiftUI
import AskKeyBroker

/// The operation's frozen summary and separately authenticated value reveal.
struct FrozenWriteApprovalContent: View {
    var writeSummary: BrokerCredentialWriteSummary?
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)?
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let writeSummary {
                let content = FrozenWriteSummaryContent(summary: writeSummary)
                ScrollView {
                    summaryRows(content.components)
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxHeight: 70)
                .accessibilityIdentifier("approval-components")
                metadataContent(content)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(appLocalized("Frozen Content to Write"))
                    .font(Theme.Fonts.caption.weight(.semibold))
                if let revealedMaterial {
                    HStack {
                        Text(revealedMaterial.title).lineLimit(1)
                        Spacer()
                        Text(revealedMaterial.encoding).foregroundStyle(Theme.textSecondary)
                        Button(appLocalized("Hide")) { self.revealedMaterial = nil }
                    }.font(Theme.Fonts.caption)
                    ScrollView {
                        Text(verbatim: revealedMaterial.content)
                            .font(Theme.Fonts.mono)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 85)
                } else {
                    HStack {
                        Text("••••••••").foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button(appLocalized("Authenticate and View"), action: reveal)
                            .disabled(revealMaterial == nil || revealing)
                            .accessibilityIdentifier("approval-reveal-frozen-material")
                    }
                    Text(appLocalized("Viewing requires separate authentication and does not approve this request."))
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.textSecondary)
                }
                if revealFailed {
                    Text(appLocalized("Unable to view: authentication was not completed or the request is no longer valid."))
                        .font(Theme.Fonts.caption).foregroundStyle(Theme.warning)
                }
            }
            .padding(Theme.Spacing.md)
            .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.group))
        }
        .font(Theme.Fonts.secondary)
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    private func metadataContent(_ content: FrozenWriteSummaryContent) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(appLocalized("Usage instructions"))
                .font(Theme.Fonts.caption.weight(.semibold))
            ScrollView {
                summaryRows(content.instructions)
            }
            .frame(height: 60)
            .accessibilityIdentifier("approval-usage-instructions")
            Text(appLocalized("Group"))
                .font(Theme.Fonts.caption.weight(.semibold))
            ScrollView {
                summaryRows(content.group)
            }
            .frame(height: 30)
            .accessibilityIdentifier("approval-group-changes")
            if content.createsGroup {
                Text(appLocalized("New group — created when approved"))
                    .foregroundStyle(Theme.warning)
                    .accessibilityIdentifier("approval-new-group")
            }
        }
        .font(Theme.Fonts.caption)
        .accessibilityIdentifier("approval-credential-metadata")
    }

    private func summaryRows(_ rows: [FrozenWriteSummaryContent.Row]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Theme.Spacing.sm, verticalSpacing: Theme.Spacing.xs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    if let label = row.label {
                        Text(verbatim: label).foregroundStyle(Theme.textSecondary).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                            summaryText(value)
                        }
                    }
                    .gridCellColumns(row.label == nil ? 2 : 1)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryText(_ value: String) -> some View {
        Text(verbatim: value)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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
