import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialManagementView {
    func credentialTag(_ text: String, accent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(accent ? Theme.brand : Theme.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(accent ? Theme.brand.opacity(0.11) : Theme.neutral(0.055), in: .rect(cornerRadius: 5))
    }

    func inlineWarning(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("⚠︎").foregroundStyle(Theme.amber)
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textMuted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.amber.opacity(0.10), in: .rect(cornerRadius: 9))
    }

}
