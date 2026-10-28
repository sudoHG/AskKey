import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorComponentLoader {
    static func load(
        _ components: [ManagedCredentialComponent],
        template: CredentialTemplate = .custom
    ) throws -> [CredentialComponentDraft] {
        // Authentication happened before loading. Current validation belongs to
        // saving, so historical mappings remain available for repair.
        return try components.map { component in
            guard let value = component.value else { throw VaultError.credentialUnavailable }
            var draft = template.components.first(where: { $0.name == component.name })
                ?? CredentialComponentDraft(name: component.name)
            draft.kind = value.payloadKind
            draft.delivery = component.delivery
            draft.masked = component.masked
            switch value {
            case .text(let text):
                draft.text = text
            case .file(let filename, let bytes):
                draft.file = try FileImport.FrozenFile(originalFilename: filename, bytes: bytes)
            }
            return draft
        }
    }
}
