import SwiftUI

struct AgentAccessPolicyNotice: View {
    @Environment(VaultViewModel.self) private var vault
    var showsResumeAction = true

    var body: some View {
        if let message = vault.agentAccessPolicyNotice {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsResumeAction {
                    Button(appLocalized("Resume Agent Access")) {
                        Task { await vault.resumeAgentAccess() }
                    }
                    .buttonStyle(.secondaryAction)
                }
            }
            .font(Theme.Fonts.caption)
            .padding(10)
            .background(Theme.warningSubtle)
            .accessibilityIdentifier("agent-access-policy-notice")
        }
    }
}
