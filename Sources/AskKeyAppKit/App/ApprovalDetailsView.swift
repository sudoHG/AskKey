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
                    Text(verbatim: ApprovalCopy.unbroken(row.label))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .accessibilityLabel(Text(verbatim: row.label))
                        .frame(width: labelWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        if let note = row.note {
                            ApprovalLineText(line: note)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        value(row.value)
                    }
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
            Text(verbatim: ApprovalCopy.wrapping(text)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: text))
        case .code(let code):
            Text(verbatim: code).font(Theme.Fonts.mono).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        case .lines(let lines):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        if line.wrapsVariables {
                            ApprovalVariableLine(line: line.text)
                                .alignmentGuide(.firstTextBaseline) { _ in NSFont.systemFont(ofSize: 12).ascender }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: line.text.plainText))
                        } else {
                            ApprovalLineText(line: line.text, tag: line.tag)
                        }
                        if let note = line.note {
                            Text(verbatim: ApprovalCopy.wrapping(note))
                                .accessibilityLabel(Text(verbatim: note))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        case .diff(let diff):
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach([false, true], id: \.self) { after in
                    Text(appLocalized(after ? "After" : "Before"))
                        .foregroundStyle(Theme.textSecondary)
                    Text(Self.attributed(after ? diff.after : diff.before))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .revealableValue:
            revealableValue
        }
    }

    /// Full before/after sentences retain context; marks also work without color.
    static func attributed(_ runs: [ApprovalTextDiff.Run]) -> AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            let leading = run.kind == .added ? String(run.text.prefix(while: \.isWhitespace)) : ""
            let trailing = run.kind == .added ? String(run.text.reversed().prefix(while: \.isWhitespace).reversed()) : ""
            let marked = run.kind == .added ? run.text.trimmingCharacters(in: .whitespacesAndNewlines) : run.text
            if marked.isEmpty { result += AttributedString(run.text); return }
            result += AttributedString(leading)
            var part = AttributedString(marked)
            switch run.kind {
            case .same: break
            case .removed:
                part.foregroundColor = Theme.warning
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = ApprovalTag.new.color
                part.underlineStyle = .single
                part.font = Theme.Fonts.secondary.weight(.semibold)
            }
            result += part
            result += AttributedString(trailing)
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
