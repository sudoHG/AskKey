import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

public enum GrokCLIAdapterError: Error, Equatable, LocalizedError {
    case unsafeConfig
    case invalidConfig
    case unsupportedClient
    case verificationFailed(String)
    case rollbackFailed
    case backupCleanupFailed
    case diagnosticsCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeConfig:
            return "The Grok CLI config is not a regular user-level file."
        case .invalidConfig:
            return "The Grok CLI config is not valid TOML."
        case .unsupportedClient:
            return "This Grok CLI build does not support user-scoped MCP management."
        case .verificationFailed(let reason):
            return "Grok CLI connection verification failed (\(reason))."
        case .rollbackFailed:
            return "Ask Key could not restore the previous Grok CLI config."
        case .backupCleanupFailed:
            return "Ask Key connected Grok CLI but could not delete the rollback backup."
        case .diagnosticsCleanupFailed:
            return "Ask Key could not remove the temporary Grok configuration probe."
        }
    }
}
