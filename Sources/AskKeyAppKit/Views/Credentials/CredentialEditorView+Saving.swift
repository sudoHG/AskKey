import AppKit
import SwiftUI
import AskKeyBroker
import AskKeyVault

extension CredentialEditorView {
    func save() {
        if let credential, !didLoadSecrets {
            if vault.updateCredentialMetadata(
                id: credential.id,
                name: name,
                usageInstructions: usageInstructions,
                groupName: groupName,
                permission: permission,
                expiresAt: parsedExpiryDate
            ) {
                close()
            }
            return
        }
        if credential == nil || payloadKind == .bundle {
            guard let input = bundleInput() else {
                vault.errorMessage = appLocalized("Complete every credential component before saving.")
                return
            }
            if let existingImportCredential {
                switch importConflictChoice {
                case .skip:
                    close()
                case .replace:
                    Task {
                        if await vault.replaceImportedBundleCredential(
                            id: existingImportCredential.id,
                            components: input.components
                        ) {
                            close()
                        }
                    }
                }
                return
            }
            if let credential {
                guard vault.updateBundleCredential(id: credential.id, input) else { return }
            } else {
                guard vault.addBundleCredential(input) else { return }
            }
        } else if payloadKind == .file {
            let input = FileCredentialInput(
                name: name,
                snapshot: snapshot,
                usageInstructions: usageInstructions,
                privateNotes: privateNotes,
                groupName: groupName,
                environmentVariable: environmentVariable.isEmpty ? nil : environmentVariable,
                permission: permission,
                expiresAt: parsedExpiryDate
            )
            if let credential {
                vault.updateFileCredential(id: credential.id, input)
            } else {
                vault.addFileCredential(input)
            }
        } else {
            let input = TextCredentialInput(
                name: name,
                value: value,
                usageInstructions: usageInstructions,
                privateNotes: privateNotes,
                groupName: groupName,
                environmentVariable: environmentVariable.isEmpty ? nil : environmentVariable,
                permission: permission,
                expiresAt: parsedExpiryDate
            )
            if let credential {
                vault.updateTextCredential(id: credential.id, input)
            } else {
                vault.addTextCredential(input)
            }
        }
        close()
    }

    func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func bundleInput() -> BundleCredentialInput? {
        guard let savedComponents = CredentialEditorComponentValidation.inputs(components) else {
            return nil
        }
        return BundleCredentialInput(
            name: name,
            components: savedComponents,
            usageInstructions: usageInstructions,
            privateNotes: privateNotes,
            groupName: groupName,
            permission: permission,
            expiresAt: parsedExpiryDate
        )
    }

    var parsedExpiryDate: Date? {
        FrozenEditorMoreSettingsPresentation.expiryDate(from: expiryDateText)
    }

    var existingImportCredential: ManagedTextCredential? {
        guard credential == nil, isEnvImport else { return nil }
        let candidate = normalizedCredentialName(name)
        return vault.credentials.first {
            normalizedCredentialName($0.name) == candidate
        }
    }

    private func normalizedCredentialName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
