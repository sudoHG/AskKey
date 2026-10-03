import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct CredentialEditorUnavailablePage: View {
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "trash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.textDim)
            Text(appLocalized("This Credential Is Unavailable"))
                .font(.system(size: 20, weight: .semibold))
            Text(appLocalized("This credential was deleted or changed. Editing and saving are no longer available."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textMuted)
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
