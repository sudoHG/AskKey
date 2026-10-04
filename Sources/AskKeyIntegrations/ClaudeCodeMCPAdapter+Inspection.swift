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
           (output.isEmpty ? diagnostic : output).hasPrefix("No MCP server named \"askkey\"."),
           output.isEmpty || diagnostic.isEmpty {
            // get is authoritative for this name. list would health-check every
            // unrelated server and connector, whose labels are not identifiers.
            return Entry(state: .absent)
        }
        guard response.status == 0, output.hasPrefix("askkey:\n") else {
            throw ClaudeCodeMCPError.unreadableConfiguration
        }
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("To remove this server, run: claude mcp remove ") { continue }
            if trimmed.isEmpty { continue }
            if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                return Entry(state: .different)
            }
            guard let colon = trimmed.firstIndex(of: ":") else {
                // An unlabelled value can be an environment assignment.
                return Entry(state: .different)
            }
            let key = String(trimmed[..<colon])
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "Environment" { return Entry(state: .different) }
            guard ["Scope", "Status", "Type", "Command", "Args"].contains(key) else { continue }
            guard fields[key] == nil else {
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
              fields["Args"] == "mcp" else {
            return Entry(state: .different)
        }
        return Entry(state: .matching, connected: fields["Status"] == "✔ Connected")
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
