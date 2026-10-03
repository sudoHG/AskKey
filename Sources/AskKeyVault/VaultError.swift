import Foundation
import Security
import AskKeyBroker

public enum KeychainFailureDisposition: Sendable {
    case cancelled
    case failed

    public static func classify(_ error: Error) -> Self? {
        switch error {
        case VaultError.keychainReadFailed(let status),
             VaultError.keychainWriteFailed(let status),
             AppKeyStoreError.securityFailure(let status):
            return status == errSecUserCanceled ? .cancelled : .failed
        case VaultError.keychainKeyUnreachable:
            return .failed
        default:
            return nil
        }
    }
}

public enum VaultError: Error, LocalizedError {
    case vaultLocked
    case vaultStorageUnavailable
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case keychainKeyUnreachable
    case invalidSecretName(String)
    case encryptionFailed
    case decryptionFailed
    case databaseError(String)
    case managementAuthenticationRequired
    case invalidCredentialName(String)
    case credentialNameConflict(String)
    case credentialNotFound(String)
    case credentialChanged
    case credentialUnavailable
    case agentAccessPaused
    case invalidFileCredential(FileCredentialIssue)

    public var errorDescription: String? {
        switch self {
        case .vaultLocked:
            return "The vault is locked. Unlock it in the AskKey app (or approve the unlock prompt) and retry."
        case .vaultStorageUnavailable:
            return "Ask Key could not open the local vault. Make sure the disk is available, then restart Ask Key. Existing data was not overwritten."
        case .keychainReadFailed(let status):
            if status == errSecAuthFailed {
                return "Keychain read denied (errSecAuthFailed, -25293). This is usually NOT a locked keychain: the process is not authorized to read the vault key, typically because the item's access-control (partition) list no longer matches the caller's code signature after a re-sign or Developer ID change. Re-add the partition with `security set-key-partition-list` for the login keychain. Do NOT delete the keychain item — that destroys the vault key and makes the vault unrecoverable. A locked keychain (`security unlock-keychain`) is only the cause if the whole login keychain is locked."
            }
            return "Keychain read failed (status \(status)). If the login keychain is locked, run `security unlock-keychain`; also confirm it is in the search list with `security list-keychains`."
        case .keychainWriteFailed(let status):
            return "Keychain write failed (status \(status))."
        case .keychainKeyUnreachable:
            return "A vault key already exists in the login keychain but could not be read, so it was not overwritten. Check that the login keychain is in the search list (`security list-keychains`) and unlocked, then relaunch."
        case .invalidSecretName:
            return "Invalid secret name. Names must be shell-safe environment variable identifiers, and must not exceed \(BrokerLimits.maximumFieldBytes) UTF-8 bytes."
        case .encryptionFailed:
            return "Failed to encrypt secret value."
        case .decryptionFailed:
            return "Failed to decrypt secret value. The vault key may have changed."
        case .databaseError(let message):
            return "Database error: \(message)"
        case .managementAuthenticationRequired:
            return "Credential management requires confirmation before it can continue."
        case .invalidCredentialName:
            return "Credential names cannot be empty, contain control characters, exceed \(CredentialName.maximumLength) characters, or exceed \(BrokerLimits.maximumFieldBytes) UTF-8 bytes."
        case .credentialNameConflict(let name):
            return "A credential named '\(name)' already exists."
        case .credentialNotFound(let name):
            return "Credential '\(name)' was not found."
        case .credentialChanged:
            return "The credential changed after this request was created. Submit a new request."
        case .credentialUnavailable:
            return "The credential is unavailable for this Agent operation."
        case .agentAccessPaused:
            return "Agent access is paused in the Ask Key app."
        case .invalidFileCredential(let issue):
            return issue.errorDescription
        }
    }
}

public enum FileCredentialIssue: Equatable, Sendable {
    case symbolicLink
    case directory
    case specialFile
    case tooLarge
    case replacedDuringRead
    case missingFile
    case digestMismatch
    case notFound

    var errorDescription: String {
        switch self {
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
}
