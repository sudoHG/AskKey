import Foundation
import AskKeyBroker

/// Adapts native command hooks to the same SSH discovery reminder as Codex.
/// It never executes tool input or accesses credentials.
enum CommandDiscoveryHook {
    /// Claude sends one JSON document terminated by EOF, rather than an MCP
    /// line. Bound its total size before attempting to decode the envelope.
    static func readClaudeInput(maximumBytes: Int) -> Data? {
        var bytes = Data()
        do {
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                guard bytes.count + chunk.count <= maximumBytes else { return nil }
                bytes.append(chunk)
            }
        } catch { return nil }
        return bytes
    }

    static func response(client: String, input: [String: Any]) throws -> [String: Any] {
        let allowed = allow(client: client)
        let event: String, session: String, tool: String, call: String?
        let turn: String?, arguments: [String: Any]
        let store = DiscoveryTurnStore(directory: try BrokerConfiguration.resolvedSocketURL()
            .deletingLastPathComponent().appendingPathComponent("credential-discovery"))
        if client == "cursor" {
            // Grok can import Cursor definitions, but delivers Grok's native
            // envelope. Ignore that invocation so its own adapter runs once.
            guard let rawEvent = input["hook_event_name"] as? String,
                  ["preToolUse", "postToolUse", "postToolUseFailure"].contains(rawEvent),
                  let rawSession = input["conversation_id"] as? String,
                  let rawTurn = input["generation_id"] as? String,
                  let rawTool = input["tool_name"] as? String else { return allowed }
            event = rawEvent == "preToolUse" ? "pre" : "post"
            session = rawSession; turn = rawTurn; tool = rawTool
            call = input["tool_use_id"] as? String
            arguments = input["tool_input"] as? [String: Any] ?? [:]
        } else if client == "grok" {
            guard let rawEvent = input["hookEventName"] as? String,
                  let rawSession = input["sessionId"] as? String else { return allowed }
            if rawEvent == "user_prompt_submit" {
                guard let prompt = input["promptId"] as? String else { return allowed }
                try store.beginGrokTurn(session: rawSession, promptID: prompt)
                return allowed
            }
            guard ["pre_tool_use", "post_tool_use", "post_tool_use_failure"].contains(rawEvent),
                  let rawTool = input["toolName"] as? String else { return allowed }
            event = rawEvent == "pre_tool_use" ? "pre" : "post"
            session = rawSession; turn = nil; tool = rawTool
            call = input["toolUseId"] as? String
            arguments = input["toolInput"] as? [String: Any] ?? [:]
        } else if client == "claude" {
            guard let rawEvent = input["hook_event_name"] as? String,
                  let rawSession = input["session_id"] as? String else { return allowed }
            if rawEvent == "UserPromptSubmit" {
                try store.beginClaudeTurn(session: rawSession)
                return allowed
            }
            guard ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(rawEvent),
                  let rawTool = input["tool_name"] as? String,
                  let rawCall = input["tool_use_id"] as? String, !rawCall.isEmpty,
                  let rawArguments = input["tool_input"] as? [String: Any] else { return allowed }
            event = rawEvent == "PreToolUse" ? "pre" : "post"
            session = rawSession; turn = nil; tool = rawTool
            call = rawCall; arguments = rawArguments
        } else { return allowed }
        // Cursor's generic event exposes MCP:<raw tool name>, without a
        // server identifier. This is a discovery reminder, not authentication.
        let catalog = client == "cursor" ? tool == "MCP:list_credentials"
            : tool == (client == "claude" ? "mcp__askkey__list_credentials" : "askkey__list_credentials")
        let shell = client == "cursor" ? tool == "Shell"
            : tool == (client == "claude" ? "Bash" : "run_terminal_command")
        guard shell || catalog else { return allowed }
        if shell {
            guard event == "pre", let command = arguments["command"] as? String,
                  CredentialDiscoveryGuard.isSSHConnection(command) else { return allowed }
        }
        let settled = try store.catalogAttemptSettled(
            client: client, session: session, turn: turn,
            callID: call, phase: event == "pre" ? .before : .after, catalog: catalog
        )
        guard event == "pre", shell, !settled else { return allowed }
        if client == "grok" || client == "claude" {
            return ["hookSpecificOutput": ["hookEventName": "PreToolUse",
                "permissionDecision": "deny", "permissionDecisionReason": reminder]]
        }
        return ["permission": "deny", "agent_message": reminder,
                "user_message": HelperLocalization.localized("Ask Key: Query the credential catalog before connecting.")]
    }

    static func allow(client: String) -> [String: Any] {
        client == "cursor" ? ["permission": "allow"] : [:]
    }

    static let reminder = """
    This SSH command has NOT run. Before the first SSH connection in this turn, call AskKey's MCP list_credentials tool to query the credential catalog. The catalog contains metadata, not secret values. If a credential matches the user's authorized task, follow its usage metadata and use AskKey's CLI with --wait-for-approval when command output is needed. After the catalog attempt finishes, this reminder lets the original connection continue; if the catalog is unavailable or no credential matches, use an appropriate existing method. If the tool cannot be called or its callback is lost, retry after 30 seconds without catalog progress; do not repeatedly retry the blocked SSH command. Do not ask the user to paste a password before checking the catalog. This reminder does not authorize a connection or grant credential access.
    """
}
