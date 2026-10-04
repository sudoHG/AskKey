import Foundation
import AskKeySystem

public enum CommandDiscoveryClient: String, Sendable {
    case cursor, grok, claude

    public func hooksURL(home: URL) -> URL {
        switch self {
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .grok: return home.appendingPathComponent(".grok/hooks/askkey-discovery.json")
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        }
    }

    public var format: CommandDiscoveryHookFormat {
        switch self {
        case .cursor: return .cursorMerged
        case .grok: return .grokOwned
        case .claude: return .claudeMerged
        }
    }

    /// Definitions contain only a signed helper path and a client selector.
    /// Event input stays on stdin; it never becomes executable shell text.
    public func definition(helper: URL) throws -> Data {
        let command = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "' hook " + rawValue
        let root: [String: Any]
        switch self {
        case .cursor:
            let handler: [String: Any] = ["command": command, "timeout": 3, "matcher": "Shell|MCP:.*"]
            root = ["version": 1, "hooks": [
                "preToolUse": [handler], "postToolUse": [handler], "postToolUseFailure": [handler],
            ]]
        case .grok:
            let commandHandler: [String: Any] = ["type": "command", "command": command, "timeout": 3]
            let toolHandler: [String: Any] = [
                "matcher": "^(run_terminal_command|askkey__list_credentials)$", "hooks": [commandHandler],
            ]
            root = ["hooks": [
                "UserPromptSubmit": [["hooks": [commandHandler]]],
                "PreToolUse": [toolHandler], "PostToolUse": [toolHandler], "PostToolUseFailure": [toolHandler],
            ]]
        case .claude:
            let handler: [String: Any] = ["type": "command", "command": command, "timeout": 3]
            let group: [String: Any] = ["matcher": "Bash|mcp__askkey__list_credentials", "hooks": [handler]]
            root = ["hooks": [
                "UserPromptSubmit": [["hooks": [handler]]],
                "PreToolUse": [group], "PostToolUse": [group], "PostToolUseFailure": [group],
            ]]
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
    }

    public func configuration(home: URL, helper: URL, backupDirectory: URL) throws -> CommandDiscoveryHookConfiguration {
        CommandDiscoveryHookConfiguration(hooksURL: hooksURL(home: home), backupDirectory: backupDirectory,
            expectedHooks: try definition(helper: helper), format: format)
    }

    /// Probes the installed helper's actual command surface, so an old helper
    /// cannot leave a newly installed rule pointing at an unsupported command.
    public func verifyHelper(_ helper: URL, workingDirectory: URL) throws {
        let result = try RestrictedProcess.run(.init(
            executable: helper, arguments: ["hook", "capabilities"],
            environment: ProcessInfo.processInfo.environment, currentDirectory: workingDirectory,
            timeout: 3, maximumOutputBytes: 8192
        ))
        guard !result.timedOut, result.status == 0,
              let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              json["protocolVersion"] as? Int == 1,
              let clients = json["clients"] as? [String], clients.contains(rawValue) else {
            throw CommandDiscoveryIntegrationError.helperUnsupported
        }
    }
}

public enum CommandDiscoveryIntegrationError: Error, Equatable, Sendable {
    case helperUnsupported
}
