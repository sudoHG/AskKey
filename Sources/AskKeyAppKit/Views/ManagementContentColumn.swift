import SwiftUI

/// Notices consume the right column's available height below the title bar.
/// The window hosts a fixed full-size shell, so reserve its title bar inside it.
struct ManagementContentColumn<Content: View>: View {
    @Environment(VaultViewModel.self) private var vault
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            AgentAccessPolicyNotice()
            if vault.brokerRecoveryAvailable {
                BrokerRecoveryNotice()
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, ManagementWindowConfiguration.titlebarClearance)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
    }
}

struct BrokerRecoveryNotice: View {
    @Environment(VaultViewModel.self) private var vault

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Theme.Fonts.caption)
                .foregroundStyle(Theme.warning)
            if let message = vault.brokerFailureMessage {
                Text(appLocalized(message))
                    .font(Theme.Fonts.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(appLocalized("Retry Agent Access")) {
                vault.retryBrokerRecovery()
            }
            .buttonStyle(.secondaryAction)
            .fixedSize()
        }
        .padding(10)
        .background(Theme.warningSubtle, ignoresSafeAreaEdges: [])
        .accessibilityIdentifier("broker-recovery-notice")
    }
}
