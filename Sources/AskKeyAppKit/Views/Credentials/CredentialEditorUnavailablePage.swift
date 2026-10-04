import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialEditorUnavailablePage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "trash")
                .font(Theme.Icon.emptyState)
                .foregroundStyle(Theme.textTertiary)
            Text(appLocalized("This Credential Is Unavailable"))
                .font(Theme.Fonts.headline)
            Text(appLocalized("This credential was deleted or changed. Editing and saving are no longer available."))
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button(appLocalized("Back to Library"), action: onBack)
                .buttonStyle(.bordered)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(appLocalized("This Credential Is Unavailable"))
    }
}
