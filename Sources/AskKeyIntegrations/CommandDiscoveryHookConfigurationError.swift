import Darwin
import Foundation

public enum CommandDiscoveryHookConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case unsafeHooksFile
    case unsafeBackupDirectory
    case invalidHooksFile
    case invalidExpectedHooks
    case fileTooLarge
    case multipleExpectedHooks
    case customHookMismatch
    case ownedFileConflict
    case concurrentModification
    case backupFailed
    case writeFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeHooksFile: return "The command-hook file is not safe."
        case .unsafeBackupDirectory: return "The command-hook backup directory is not safe."
        case .invalidHooksFile: return "The command-hook file is invalid."
        case .invalidExpectedHooks: return "The reviewed command-hook definition is invalid."
        case .fileTooLarge: return "The command-hook file is too large."
        case .multipleExpectedHooks: return "Multiple Ask Key command hooks were found."
        case .customHookMismatch: return "An Ask Key command hook has been customized."
        case .ownedFileConflict: return "The Grok command-hook file contains unknown settings."
        case .concurrentModification: return "The command-hook file changed after review."
        case .backupFailed: return "The command-hook backup failed."
        case .writeFailed: return "The command hook could not be written."
        case .rollbackFailed: return "The command-hook rollback failed."
        }
    }
}
