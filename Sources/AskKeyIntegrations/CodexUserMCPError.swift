import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public enum CodexUserMCPError: Error, Equatable, LocalizedError {
    case unsafeConfigFile
    case illegalConfig
    case unknownCodexVersion
    case connectionFailed(String)
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeConfigFile:
            return "The Codex config file is not a safe regular file."
        case .illegalConfig:
            return "The Codex config file is not valid TOML."
        case .unknownCodexVersion:
            return "The Codex version is unknown and cannot be configured."
        case .connectionFailed(let reason):
            return "Ask Key could not verify the Codex connection (\(reason))."
        case .rollbackFailed:
            return "Ask Key could not restore the original Codex config. The managed backup was kept for recovery."
        }
    }
}
