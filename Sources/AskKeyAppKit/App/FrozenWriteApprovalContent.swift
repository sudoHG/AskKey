import SwiftUI
import AskKeyBroker

/// The frozen content of a create, modify or delete approval: the before and
/// after summary and the separately authenticated reveal of the values.
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
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(appLocalized("Before"))
                        ForEach(Array(writeSummary.before.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                        Text(appLocalized("After"))
                        ForEach(Array(writeSummary.after.enumerated()), id: \.offset) { _, item in
                            Text("\(item.name) · \(item.byteCount) B · \(item.delivery.environmentVariable ?? "App")")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxHeight: 70)
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
