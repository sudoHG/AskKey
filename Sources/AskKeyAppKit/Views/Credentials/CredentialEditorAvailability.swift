import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorAvailability: Equatable {
    case create(template: CredentialTemplate)
    case edit(template: CredentialTemplate, credential: ManagedTextCredential)
    case unavailable(id: String)

    static func resolve(
        template: CredentialTemplate,
        credentialID: String?,
        credentials: [ManagedTextCredential]
    ) -> CredentialEditorAvailability {
        guard let credentialID else { return .create(template: template) }
        if let credential = credentials.first(where: { $0.id == credentialID }) {
            return .edit(template: template, credential: credential)
        }
        return .unavailable(id: credentialID)
    }
}
