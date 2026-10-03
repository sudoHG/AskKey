import Darwin
import Foundation

public enum CodexDiscoveryHookConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case unsafeHooksFile
    case unsafeBackupDirectory
    case invalidHooksFile
    case fileTooLarge
    case multipleExpectedHooks
    case customHookMismatch
    case concurrentModification
    case backupFailed
    case writeFailed
    case rollbackFailed
    case restoreConflict

    public var errorDescription: String? {
        switch self {
        case .unsafeHooksFile:
            return "The Codex hooks file is not a safe regular file."
        case .unsafeBackupDirectory:
            return "The Ask Key Codex hook backup directory is not safe."
        case .invalidHooksFile:
            return "The Codex hooks file is not valid JSON hook configuration."
        case .fileTooLarge:
            return "The Codex hooks file is too large to inspect safely."
        case .multipleExpectedHooks:
            return "Multiple Ask Key discovery hooks were found."
        case .customHookMismatch:
            return "An existing Ask Key discovery hook has been customized."
        case .concurrentModification:
            return "The Codex hooks file changed after it was reviewed."
        case .backupFailed:
            return "The previous Codex hooks file could not be backed up safely."
        case .writeFailed:
            return "The Ask Key Codex discovery hook could not be written."
        case .rollbackFailed:
            return "The previous Codex hooks file could not be restored safely."
        case .restoreConflict:
            return "The Codex hooks file changed before restoration."
        }
    }
}
