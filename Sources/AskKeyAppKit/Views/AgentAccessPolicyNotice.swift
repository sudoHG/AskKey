import SwiftUI

struct AgentAccessPolicyNotice: View {
    @Environment(VaultViewModel.self) private var vault
    var showsResumeAction = true
    var usesCompactRecoveryMessage = false

    var body: some View {
        if let message = Self.displayedMessage(vault.agentAccessPolicyNotice, compactRecovery: usesCompactRecoveryMessage) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text(message)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if showsResumeAction {
                    Button(appLocalized("Resume Agent Access")) {
                        Task { await vault.resumeAgentAccess() }
                    }
                    .buttonStyle(.secondaryAction)
                    .fixedSize()
                }
            }
            .font(Theme.Fonts.caption)
            .padding(10)
            .background(Theme.warningSubtle, ignoresSafeAreaEdges: [])
            .accessibilityIdentifier("agent-access-policy-notice")
        }
    }

    static func displayedMessage(_ message: String?, compactRecovery: Bool) -> String? {
        guard compactRecovery, let message else { return message }
        let summary = appLocalized("Agent access is paused until you confirm its settings.")
        // The policy notice can include independent read/save failures. Shorten
        // only the recovery paragraph and preserve every other notice verbatim.
        return message.components(separatedBy: "\n")
            .map { $0.hasPrefix(summary) ? summary : $0 }
            .joined(separator: "\n")
    }
}
