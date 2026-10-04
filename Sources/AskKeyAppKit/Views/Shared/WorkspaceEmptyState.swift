import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

struct WorkspaceEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: systemImage)
                .font(Theme.Icon.emptyState)
                .foregroundStyle(Theme.textTertiary)
            Text(title)
                .font(Theme.Fonts.headline)
                .foregroundStyle(Theme.text)
            Text(message)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
