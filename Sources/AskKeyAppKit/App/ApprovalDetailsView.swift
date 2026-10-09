import SwiftUI
import AskKeyBroker

/// Details as one two-column list: a fixed-width label in the secondary color
/// and its value, all at the 12-point size. New values stay masked until
/// viewed with a separate authentication, which doesn't approve.
struct ApprovalDetailsView: View {
    let content: ApprovalDetailsContent
    var revealMaterial: (@MainActor () async throws -> FrozenApprovalMaterial)?
    @State private var revealedMaterial: FrozenApprovalMaterial?
    @State private var revealing = false
    @State private var revealFailed = false
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        let labelWidth = ApprovalDetailsContent.labelWidth()
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Rectangle().fill(Theme.separator).frame(height: 1)
            ForEach(Array(content.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(verbatim: row.label)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: labelWidth, alignment: .leading)
                    value(row.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(Theme.Fonts.secondary)
        .foregroundStyle(Theme.text)
        .onDisappear { revealTask?.cancel(); revealTask = nil; revealedMaterial = nil }
    }

    @ViewBuilder
    private func value(_ value: ApprovalDetailsContent.Value) -> some View {
        switch value {
        case .text(let text):
            Text(verbatim: text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            Text(verbatim: code).font(Theme.Fonts.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .lines(let lines):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        ApprovalLineText(line: line.text, tag: line.tag)
                        if let note = line.note {
                            Text(verbatim: note)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        case .diff(let diff):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(Self.attributed(diff.merged)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if !diff.removedPhrases.isEmpty {
                    Text(verbatim: appLocalizedFormat("Removed phrases: %@",
                        diff.removedPhrases.map(ApprovalCopy.quoted).joined(separator: appLocalized("List separator"))))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("approval-instructions-removed")
                }
            }
        case .revealableValue:
            revealableValue
        }
    }

    /// Removed words in red with a line through them, added words in green.
    private static func attributed(_ runs: [ApprovalTextDiff.Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
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
        }
    }

    @ViewBuilder
    private var revealableValue: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let revealedMaterial {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(revealedMaterial.title).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    Text(revealedMaterial.encoding).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Button(appLocalized("Hide")) { self.revealedMaterial = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
                ApprovalScrollArea(space: "approval-revealed-value", maxHeight: 85, indicatorOffset: Theme.Spacing.sm - 2) {
                    Text(verbatim: revealedMaterial.content)
                        .font(Theme.Fonts.mono)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Spacing.sm)
                .background(Theme.neutralSubtle, in: .rect(cornerRadius: Theme.Radius.control))
                .accessibilityIdentifier("approval-revealed-value")
            } else {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(verbatim: "••••••")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityLabel(Text(appLocalized("Hidden value")))
                    Button(appLocalized("Authenticate to View"), action: reveal)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                        .disabled(revealMaterial == nil || revealing)
                        .accessibilityIdentifier("approval-reveal-frozen-material")
                }
            }
            if revealFailed {
                Text(appLocalized("Unable to view: authentication was not completed or the request is no longer valid."))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
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
