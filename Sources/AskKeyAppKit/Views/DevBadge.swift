import SwiftUI
import AskKeyVault

/// A small "DEV" pill rendered only in development builds, so the dev app is
/// never mistaken for the installed production app (they use separate vaults).
/// Renders nothing in release builds.
struct DevBadge: View {
    var body: some View {
        if VaultConfiguration.isDevelopmentBuild {
            Text("DEV")
                .font(Theme.Fonts.caption.bold())
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.neutralSubtle))
                .help("Development build — uses a separate vault from the production app")
        }
    }
}
