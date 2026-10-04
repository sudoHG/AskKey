import Foundation

public struct ClaudeCodeMCPPlan: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case absent
        case matching
        case different
        case scopeConflict
    }

    public let version: String
    public let state: State
}

public struct ClaudeCodeMCPConnectionStatus: Equatable, Sendable {
    public let connected: Bool
    public let reason: String
    public let version: String
    public let helperVersion: String
}

public enum ClaudeCodeMCPError: Error, Equatable, Sendable {
    case missingExecutable
    case unsupportedVersion
    case unsupportedCLI
    case unreadableConfiguration
    case conflictingEntry
    case conflictingScope
    case configurationChanged
    case addFailed
    case verificationFailed(String)
    case rollbackFailed(original: String, cleanup: String)
    case cancelled
    case timeout
    case outputTooLarge
    case processFailed
}
