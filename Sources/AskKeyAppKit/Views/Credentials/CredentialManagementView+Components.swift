import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    func credentialTag(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(Theme.Fonts.caption)
            .foregroundStyle(accent ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(accent ? Theme.accentSubtle : Theme.neutralSubtle, in: .rect(cornerRadius: 5))
    }

    func inlineWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠︎").foregroundStyle(Theme.warning)
            Text(message)
                .font(Theme.Fonts.secondary)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warningSubtle, in: .rect(cornerRadius: 9))
    }

}
