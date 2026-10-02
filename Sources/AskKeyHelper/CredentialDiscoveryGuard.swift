import Foundation

/// A per-turn discovery reminder. This never reads the vault, executes a
/// command, or grants credential access; the Broker remains the authority.
final class CredentialDiscoveryGuard {
    private struct Turn: Hashable {
        let session: String
        let turn: String
    }
    private var catalogAttempts: Set<Turn> = []
    private var pendingCatalogAttempts: [String: Turn] = [:]
    private var pendingOrder: [String] = []
    private var order: [Turn] = []

    func catalogAttemptFinished(token: String?) {
        guard let token, let turn = pendingCatalogAttempts.removeValue(forKey: token) else { return }
        pendingOrder.removeAll { $0 == token }
        if catalogAttempts.insert(turn).inserted {
            order.append(turn)
            if order.count > 1024 { catalogAttempts.remove(order.removeFirst()) }
        }
    }

    func response(to arguments: [String: Any]) -> [String: Any] {
        guard let session = arguments["session_id"] as? String, !session.isEmpty,
              let turnID = arguments["turn_id"] as? String, !turnID.isEmpty,
              let tool = arguments["tool_name"] as? String else { return [:] }
        let turn = Turn(session: session, turn: turnID)
        if tool == "mcp__askkey__list_credentials" {
            if !catalogAttempts.contains(turn) {
                let token = UUID().uuidString
                pendingCatalogAttempts[token] = turn
                pendingOrder.append(token)
                if pendingOrder.count > 1024 { pendingCatalogAttempts.removeValue(forKey: pendingOrder.removeFirst()) }
                var input = arguments["tool_input"] as? [String: Any] ?? [:]
                input["discovery_token"] = token
                return ["hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "allow",
                    "updatedInput": input,
                ]]
            }
            return [:]
        }
        guard tool == "Bash", !catalogAttempts.contains(turn),
              let input = arguments["tool_input"] as? [String: Any],
              let command = input["command"] as? String,
              Self.isSSHConnection(command) else { return [:] }
        return ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": """
            This SSH command has NOT run. Before the first SSH connection in this turn, discover AskKey's list_credentials tool and query its credential catalog. In Code Mode, search ALL_TOOLS for askkey/list_credentials, then call the discovered tool. Catalog lookup returns metadata, not secret values. If a credential matches the user's authorized task, follow its usage metadata and AskKey's run instructions; use the CLI with --wait-for-approval when command output is needed. If the catalog is unavailable or no credential matches, continue with an appropriate existing connection method. Do not ask the user to paste a password before checking the catalog. This reminder does not authorize any connection or grant credential access.
            """,
        ]]
    }

    static func isSSHConnection(_ command: String, depth: Int = 0) -> Bool {
        guard depth < 4, let commands = shellCommands(command) else { return false }
        return commands.contains { words in
            var words = words
            while words.first?.range(of: "^[A-Za-z_][A-Za-z_0-9]*=", options: .regularExpression) != nil {
                words.removeFirst()
            }
            if words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) == "env" {
                words.removeFirst()
                while words.first?.range(of: "^[A-Za-z_][A-Za-z_0-9]*=", options: .regularExpression) != nil {
                    words.removeFirst()
                }
            }
            guard let first = words.first else { return false }
            let executable = URL(fileURLWithPath: first).lastPathComponent
            if ["sh", "bash", "zsh"].contains(executable), words.count >= 3,
               ["-c", "-lc"].contains(words[1]) {
                return isSSHConnection(words[2], depth: depth + 1)
            }
            guard executable == "ssh" else { return false }
            // Interpret only SSH options before the destination, never words in
            // the remote command. -G, -Q and -V do not connect to a host.
            let takesValue = Set("BbcDEeFIiJLlmOopQRSWw")
            var index = 1
            while index < words.count {
                let word = words[index]
                if word == "--" { return index + 1 < words.count }
                if !word.hasPrefix("-") { return !word.isEmpty }
                let flags = Array(word.dropFirst())
                for (offset, flag) in flags.enumerated() {
                    if "GQV".contains(flag) { return false }
                    if takesValue.contains(flag) {
                        if offset == flags.count - 1 { index += 1 }
                        break
                    }
                }
                index += 1
            }
            return false
        }
    }

    /// Recognize common literal shell commands without running a shell. Shell
    /// substitutions and input redirects are deliberately left alone. Simple
    /// variables remain literal tokens: their values are not needed to spot ssh.
    /// this is a helpful routing reminder, not a shell security parser.
    private static func shellCommands(_ command: String) -> [[String]]? {
        var commands: [[String]] = []
        var words: [String] = []
        var word = ""
        var started = false
        var quote: Character?
        var escaped = false
        func finishWord() {
            if started { words.append(word); word = ""; started = false }
        }
        func finishCommand() {
            finishWord()
            if !words.isEmpty { commands.append(words); words = [] }
        }
        for character in command {
            if escaped { word.append(character); started = true; escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
                else {
                    if currentQuote == "\"", character == "`" { return nil }
                    word.append(character)
                }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if "<`()".contains(character) { return nil }
            else if character == ">" { finishWord(); words.append(">") }
            else if character == "#", !started { return nil }
            else if ";|&\n".contains(character) { finishCommand() }
            else if character.isWhitespace { finishWord() }
            else { word.append(character); started = true }
        }
        guard quote == nil, !escaped else { return nil }
        finishCommand()
        return commands
    }
}
