import Foundation
import AskKeyCore

enum UserFacingCopy {
    static func message(for error: Error) -> String {
        if KeychainFailureDisposition.classify(error) == .failed {
            return localized("Ask Key could not access the vault. Allow Keychain access, then try again.")
        }
        if let vaultError = error as? VaultError {
            return message(for: vaultError)
        }
        if let description = (error as? LocalizedError)?.errorDescription {
            return displayedUserMessage(description)
        }
        return displayedUserMessage(error.localizedDescription)
    }

    static func message(for error: VaultError) -> String {
        switch error {
        case .credentialNameConflict(let name):
            return format("A credential named \"%@\" already exists.", name)
        case .credentialNotFound(let name):
            return format("Credential \"%@\" was not found.", name)
        case .invalidCredentialName:
            return localized(
                "Credential names cannot be empty, contain control characters, exceed 255 characters, or exceed 4096 UTF-8 bytes."
            )
        case .vaultStorageUnavailable:
            return localized(
                "Ask Key could not open the local vault. Make sure the disk is available, then restart Ask Key. Existing data was not overwritten."
            )
        case .keychainReadFailed, .keychainWriteFailed, .keychainKeyUnreachable:
            return localized("Ask Key could not access the vault. Allow Keychain access, then try again.")
        case .managementAuthenticationRequired:
            return localized("Credential management requires confirmation before it can continue.")
        case .credentialChanged:
            return localized("The credential changed after this request was created. Submit a new request.")
        case .credentialUnavailable:
            return localized("The credential is unavailable for this Agent operation.")
        case .agentAccessPaused:
            return localized("Agent access is paused in the Ask Key app.")
        case .invalidFileCredential(let issue):
            return localized(fileIssueKey(issue))
        case .databaseError, .keyDerivationFailed, .secretNotFound, .secretAlreadyExists,
             .projectNotFound, .projectAlreadyExists, .projectContainsSecrets,
             .environmentNotFound, .environmentAlreadyExists, .environmentContainsSecrets,
             .invalidSecretName:
            return localized("Ask Key could not complete this change.")
        default:
            if let description = error.errorDescription, AppLanguage.containsKey(description) {
                return localized(description)
            }
            return localized("Ask Key could not complete this change.")
        }
    }

    private static func fileIssueKey(_ issue: FileCredentialIssue) -> String {
        switch issue {
        case .symbolicLink:
            return "AskKey only imports ordinary files. Symbolic links are not allowed."
        case .directory:
            return "AskKey only imports ordinary files. Directories are not allowed."
        case .specialFile:
            return "AskKey only imports ordinary files. Special files are not allowed."
        case .tooLarge:
            return "This file is larger than AskKey's 5 MB import limit."
        case .replacedDuringRead:
            return "The file changed while AskKey was reading it. Import was cancelled."
        case .missingFile:
            return "Choose an ordinary file before saving this credential."
        case .digestMismatch:
            return "Stored file bytes do not match the saved digest."
        case .notFound:
            return "The file could not be read."
        }
    }

    private static func localized(_ key: String) -> String {
        AppLanguage.localized(key, language: AppLanguage.current)
    }

    private static func format(_ key: String, _ argument: String) -> String {
        let language = AppLanguage.current
        let format = AppLanguage.localized(key, language: language)
        return String(format: format, locale: AppLanguage.locale(for: language), arguments: [argument])
    }
}

func displayedUserMessage(_ stored: String, language: String? = nil) -> String {
    AppLanguage.localized(stored, language: language ?? AppLanguage.current)
}
