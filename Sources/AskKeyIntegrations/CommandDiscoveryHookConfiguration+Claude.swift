import Foundation

extension CommandDiscoveryHookConfiguration {
    struct ClaudeMatch {
        let event: String
        let group: Int
        let handler: Int
    }

    func claudeDefinition(_ root: [String: Any]) throws -> Definition {
        guard let hooks = root["hooks"] as? [String: Any],
              Set(hooks.keys) == Set(["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"])
        else { throw Error.invalidExpectedHooks }
        var groups: [String: [[String: Any]]] = [:]
        var commands: [String] = []
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]], entries.count == 1,
                  let handlers = entries[0]["hooks"] as? [[String: Any]], handlers.count == 1,
                  handlers[0]["type"] as? String == "command",
                  let command = handlers[0]["command"] as? String, !command.isEmpty,
                  (event == "UserPromptSubmit" ? entries[0]["matcher"] == nil
                    : entries[0]["matcher"] as? String == "Bash|mcp__askkey__list_credentials")
            else { throw Error.invalidExpectedHooks }
            groups[event] = entries
            commands.append(command)
        }
        guard Set(commands).count == 1 else { throw Error.invalidExpectedHooks }
        return Definition(root: root, groups: groups, commands: commands,
                          canonical: try serialize(root, error: .invalidExpectedHooks))
    }

    func claudeMatches(in document: [String: Any], definition: Definition) throws -> [ClaudeMatch] {
        guard let value = document["hooks"] else { return [] }
        guard let hooks = value as? [String: Any] else { throw Error.invalidHooksFile }
        var matches: [ClaudeMatch] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { throw Error.invalidHooksFile }
            for (groupIndex, group) in groups.enumerated() {
                guard let handlers = group["hooks"] as? [[String: Any]] else { throw Error.invalidHooksFile }
                for (handlerIndex, handler) in handlers.enumerated() {
                    guard let command = handler["command"] as? String else { continue }
                    let lower = command.lowercased()
                    guard definition.commands.contains(command) || lower.contains("hook claude")
                        || lower.contains("askkey") || lower.contains("ask key") else { continue }
                    guard let expectedGroup = definition.groups[event]?.first,
                          let expectedHandler = (expectedGroup["hooks"] as? [[String: Any]])?.first,
                          jsonEqual(handler, expectedHandler),
                          jsonEqual(group.filter { $0.key != "hooks" }, expectedGroup.filter { $0.key != "hooks" })
                    else { throw Error.customHookMismatch }
                    matches.append(ClaudeMatch(event: event, group: groupIndex, handler: handlerIndex))
                }
            }
        }
        guard Dictionary(grouping: matches, by: \.event).values.allSatisfy({ $0.count == 1 })
        else { throw Error.multipleExpectedHooks }
        return matches
    }

    func claudePlan(snapshot: Snapshot?, definition: Definition) throws -> CommandDiscoveryHookPlan {
        let bytes = snapshot?.bytes ?? Data("{}".utf8)
        var document = try CommandHookJSON.parse(bytes)
        let existing = try object(bytes, error: .invalidHooksFile)
        let matches = try claudeMatches(in: existing, definition: definition)
        if matches.count == definition.groups.count { return claudeNoChange(snapshot) }
        var hooks = document.member("hooks") ?? CommandHookJSON.emptyObject
        for event in definition.groups.keys.sorted() where !matches.contains(where: { $0.event == event }) {
            var groups = hooks.member(event) ?? CommandHookJSON.emptyArray
            try groups.append(try CommandHookJSON.generated(serialize(definition.groups[event]![0], error: .invalidExpectedHooks)))
            try hooks.set(event, to: groups)
        }
        try document.set("hooks", to: hooks)
        return try claudeChanged(snapshot, after: document.bytes, summary: "Add Ask Key's Claude Code discovery command hooks.")
    }

    /// Remove only exact owned handlers, including those beside other tools
    /// inside a shared matcher group. Customized handlers stop removal.
    public func removeClaudeHooks() throws {
        lock.lock(); defer { lock.unlock() }
        guard format == .claudeMerged else { throw Error.invalidExpectedHooks }
        let definition = try makeDefinition()
        let snapshot = try readSnapshot(at: hooksURL, checkParent: true)
        try applyLocked(plan: claudeRemovalPlan(snapshot: snapshot, definition: definition), removingClaude: true)
    }

    func claudeRemovalPlan(snapshot: Snapshot?, definition: Definition) throws -> CommandDiscoveryHookPlan {
        guard let snapshot else { return claudeNoChange(nil) }
        var document = try CommandHookJSON.parse(snapshot.bytes)
        let matches = try claudeMatches(in: object(snapshot.bytes, error: .invalidHooksFile), definition: definition)
        guard !matches.isEmpty else { return claudeNoChange(snapshot) }
        var hooks = try document.requiredMember("hooks")
        for match in matches {
            var groups = try hooks.requiredMember(match.event)
            var group = try groups.element(match.group)
            var handlers = try group.requiredMember("hooks")
            try handlers.remove(match.handler)
            if handlers.isEmptyArray {
                try groups.remove(match.group)
            } else {
                try group.set("hooks", to: handlers)
                try groups.setElement(match.group, to: group)
            }
            // Keep the event key, its remaining groups and all unrelated keys.
            try hooks.set(match.event, to: groups)
        }
        try document.set("hooks", to: hooks)
        return try claudeChanged(snapshot, after: document.bytes, summary: "Remove Ask Key's Claude Code discovery command hooks.")
    }

    private func claudeNoChange(_ snapshot: Snapshot?) -> CommandDiscoveryHookPlan {
        CommandDiscoveryHookPlan(before: snapshot?.bytes, after: snapshot?.bytes, changed: false,
            summary: "Claude Code discovery command hooks are unchanged.", format: format,
            beforeMode: snapshot?.mode, afterMode: snapshot?.mode ?? 0o600)
    }

    private func claudeChanged(_ snapshot: Snapshot?, after: Data, summary: String) throws -> CommandDiscoveryHookPlan {
        guard after.count <= Self.maximumHooksBytes else { throw Error.fileTooLarge }
        return CommandDiscoveryHookPlan(before: snapshot?.bytes, after: after, changed: true, summary: summary,
            format: format, beforeMode: snapshot?.mode, afterMode: snapshot?.mode ?? 0o600)
    }
}
