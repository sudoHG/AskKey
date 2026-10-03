import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

enum CredentialEditorComponentLoader {
    static func load(
        _ components: [ManagedCredentialComponent],
        template: CredentialTemplate = .custom
    ) throws -> [CredentialComponentDraft] {
        let inputs = try components.map { component -> CredentialComponentInput in
            guard let value = component.value else { throw VaultError.credentialUnavailable }
            return CredentialComponentInput(name: component.name, value: value, delivery: component.delivery, masked: component.masked)
        }
        return try CredentialBundleValidator.validatedComponents(inputs).map { component in
            var draft = template.components.first(where: { $0.name == component.name })
                ?? CredentialComponentDraft(name: component.name)
            draft.delivery = component.delivery
            draft.masked = component.masked
            switch component.value {
            case .text(let text):
                draft.text = text
            case .file(let filename, let bytes):
                draft.kind = .file
                draft.file = try FileImport.FrozenFile(originalFilename: filename, bytes: bytes)
            }
            return draft
        }
    }
}
