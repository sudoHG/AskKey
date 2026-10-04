import Foundation
import AskKeySystem

/// User-scope MCP configuration is owned by Claude's CLI, never by a file writer.
public struct ClaudeCodeMCPAdapter: Sendable {
    /// Provisional until the real-client acceptance in #127 confirms the floor.
    public static let minimumVersion = "2.1.0"

    public let homeDirectory: URL
    public let workingDirectory: URL
    public let helperURL: URL
    public let claudeExecutable: URL
    public let brokerSocketPath: String
    public let signing: CodexHelperSigning
    public var commandTimeout: TimeInterval = 12
    public var terminationGrace: TimeInterval = 0.2
    let executableSearchPath: String

    public init(
        homeDirectory: URL,
        workingDirectory: URL,
        helperURL: URL,
        brokerSocketPath: String,
        claudeExecutable: URL? = nil,
        signing: CodexHelperSigning = .executable,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) {
        self.homeDirectory = homeDirectory
        self.workingDirectory = workingDirectory
        self.helperURL = helperURL
        self.brokerSocketPath = brokerSocketPath
        self.signing = signing
        let paths = [homeDirectory.appendingPathComponent(".local/bin").path]
            + searchPath.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        executableSearchPath = paths.joined(separator: ":")
        self.claudeExecutable = claudeExecutable
            ?? paths.map { URL(fileURLWithPath: $0).appendingPathComponent("claude") }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
            ?? homeDirectory.appendingPathComponent(".local/bin/claude")
    }

    public func plan() throws -> ClaudeCodeMCPPlan {
        let version = try preflight()
        return ClaudeCodeMCPPlan(version: version, state: try inspectEntry().state)
    }

    public func connect() throws -> ClaudeCodeMCPConnectionStatus {
        let plan = try plan()
        switch plan.state {
        case .different: throw ClaudeCodeMCPError.conflictingEntry
        case .scopeConflict: throw ClaudeCodeMCPError.conflictingScope
        case .matching: return try verify(version: plan.version)
        case .absent: break
        }
        // Recheck immediately before the write; a preview is never write authority.
        guard try inspectEntry().state == .absent else {
            throw ClaudeCodeMCPError.configurationChanged
        }
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "stdio", "command": helperURL.path, "args": ["mcp"],
        ], options: [.sortedKeys])
        let added = try runClaude(["mcp", "add-json", "askkey", String(decoding: json, as: UTF8.self), "--scope", "user"])
        guard added.status == 0 else { throw ClaudeCodeMCPError.addFailed }
        do {
            let status = try verify(version: plan.version)
            guard status.connected else { throw ClaudeCodeMCPError.verificationFailed(status.reason) }
            return status
        } catch {
            // Cancellation still requires bounded cleanup of this transaction's write.
            do { try RestrictedProcessCancellation.withValue({ false }) { try rollback() } }
            catch let cleanupError {
                throw ClaudeCodeMCPError.rollbackFailed(
                    original: failureReason(error), cleanup: failureReason(cleanupError)
                )
            }
            throw error
        }
    }

    public func verify() throws -> ClaudeCodeMCPConnectionStatus {
        try verify(version: preflight())
    }

    func failureReason(_ error: Error) -> String {
        if let error = error as? ClaudeCodeMCPError { return String(describing: error) }
        return "process_failed"
    }
}
