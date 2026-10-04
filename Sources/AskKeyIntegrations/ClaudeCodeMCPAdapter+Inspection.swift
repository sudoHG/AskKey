import Foundation

extension ClaudeCodeMCPAdapter {
    struct Entry {
        let state: ClaudeCodeMCPPlan.State
        var connected = false
    }

    func inspectEntry(cleanup: Bool = false) throws -> Entry {
        let response = try runClaude(["mcp", "get", "askkey"], cleanup: cleanup)
        let output = String(decoding: response.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnostic = String(decoding: response.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if response.status == 1,
           (output.isEmpty ? diagnostic : output) == "No MCP server found with name: askkey",
           output.isEmpty || diagnostic.isEmpty {
            let listed = try runClaude(["mcp", "list"], cleanup: cleanup)
            let list = String(decoding: listed.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard listed.status == 0 else { throw ClaudeCodeMCPError.unreadableConfiguration }
            if list == "No MCP servers configured. Use `claude mcp add` to add a server." {
                return Entry(state: .absent)
            }
            let lines = list.split(whereSeparator: \.isNewline).map(String.init)
            guard lines.first == "Checking MCP server health...", lines.count > 1,
                  lines.dropFirst().allSatisfy({ $0.range(of: #"^[^\s:]+: .+ - .+$"#, options: .regularExpression) != nil }),
                  !lines.dropFirst().contains(where: { $0.hasPrefix("askkey:") }) else {
                throw ClaudeCodeMCPError.unreadableConfiguration
            }
            return Entry(state: .absent)
        }
        guard response.status == 0, output.hasPrefix("askkey:\n") else {
            throw ClaudeCodeMCPError.unreadableConfiguration
        }
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("To remove this server, run: claude mcp remove ") { continue }
            guard let colon = trimmed.firstIndex(of: ":") else {
                // Environment assignments or a changed output contract are unsafe.
                return Entry(state: .different)
            }
            let key = String(trimmed[..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil, ["Scope", "Status", "Type", "Command", "Args", "Environment"].contains(key) else {
                return Entry(state: .different)
            }
            fields[key] = value
        }
        guard let scope = fields["Scope"], !scope.isEmpty else {
            throw ClaudeCodeMCPError.unreadableConfiguration
        }
        guard scope == "User config (available in all your projects)" else {
            return Entry(state: .scopeConflict)
        }
        guard fields["Type"] == "stdio", fields["Command"] == helperURL.path,
              fields["Args"] == "mcp", fields["Environment", default: ""].isEmpty else {
            return Entry(state: .different)
        }
        return Entry(state: .matching, connected: fields["Status"] == "✓ Connected")
    }

    func rollback() throws {
        let current = try inspectEntry(cleanup: true)
        if current.state == .absent { return }
        guard current.state == .matching else { throw ClaudeCodeMCPError.configurationChanged }
        let removed = try runClaude(["mcp", "remove", "askkey", "--scope", "user"], cleanup: true)
        guard removed.status == 0, try inspectEntry(cleanup: true).state == .absent else {
            throw ClaudeCodeMCPError.verificationFailed("rollback_absence")
        }
    }
}
