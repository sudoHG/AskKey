import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

public enum CursorMCPError: Error, Equatable, LocalizedError {
    case unsafeFile
    case invalidJSON
    case replaceFailed
    case readbackFailed
    case rollbackFailed
    case backupCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            return "Ask Key will not write a Cursor MCP config that is a symbolic link or special file."
        case .invalidJSON:
            return "The Cursor MCP config is not valid JSON, so it was left unchanged."
        case .replaceFailed:
            return "Ask Key could not replace the Cursor MCP config."
        case .readbackFailed:
            return "The Cursor MCP config could not be verified after writing."
        case .rollbackFailed:
            return "Ask Key could not restore the original Cursor MCP config. The managed backup was kept for recovery."
        case .backupCleanupFailed:
            return "Ask Key verified Cursor, but could not remove the managed backup. The connection was not marked successful."
        }
    }
}
