import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum FrozenCredentialDetailCopy {
    static var protectionTitle: String { appLocalized("Plaintext Protection") }
    static var protectionMessage: String { appLocalized("Even while management is unlocked, revealing or copying plaintext requires authentication. Copied content clears after 60 seconds.") }

    static func kindLabel(
        componentName: String,
        kind: CredentialPayloadKind = .text
    ) -> String {
        if kind == .file { return appLocalized("File") }
        switch componentName {
        case "API_KEY", "ISSUER_ID", "KEY_ID", "TEAM_ID", "SSH_PASSPHRASE",
             "ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "SESSION_TOKEN", "DB_PASSWORD":
            return appLocalized("Protected")
        default:
            return appLocalized("Text")
        }
    }
}
