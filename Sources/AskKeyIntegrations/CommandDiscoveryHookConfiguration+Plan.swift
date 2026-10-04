import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    public func preview() throws -> CommandDiscoveryHookPlan {
        lock.lock(); defer { lock.unlock() }
        let definition = try makeDefinition()
        return try makePlan(snapshot: try readSnapshot(at: hooksURL, checkParent: true), definition: definition)
    }

    func makePlan(snapshot: Snapshot?, definition: Definition) throws -> CommandDiscoveryHookPlan {
        switch format {
        case .claudeMerged:
            return try claudePlan(snapshot: snapshot, definition: definition)
        case .grokOwned:
            if let snapshot {
                let existing = try object(snapshot.bytes, error: .invalidHooksFile)
                if jsonEqual(existing, definition.root) { return noChange(snapshot) }
                if containsOwnLike(in: existing, commands: definition.commands) {
                    throw Error.customHookMismatch
                }
                throw Error.ownedFileConflict
            }
            return CommandDiscoveryHookPlan(
                before: nil, after: definition.canonical, changed: true,
                summary: "Add Ask Key's Grok discovery command hook.", format: format,
                beforeMode: nil, afterMode: 0o600
            )

        case .cursorMerged:
            guard let snapshot else {
                return CommandDiscoveryHookPlan(
                    before: nil, after: definition.canonical, changed: true,
                    summary: "Add Ask Key's Cursor discovery command hooks.", format: format,
                    beforeMode: nil, afterMode: 0o600
                )
            }
            let existing = try object(snapshot.bytes, error: .invalidHooksFile)
            let found = try cursorMatches(in: existing, definition: definition)
            try validate(found, expected: definition.groups)
            let exactCount = found.filter(\.exact).count
            let expectedCount = definition.groups.values.reduce(0) { $0 + $1.count }
            if exactCount == expectedCount {
                return noChange(snapshot)
            }
            var merged = existing
            try append(to: &merged, definition: definition)
            return CommandDiscoveryHookPlan(
                before: snapshot.bytes, after: try serialize(merged, error: .invalidHooksFile), changed: true,
                summary: "Add Ask Key's Cursor discovery command hooks.", format: format,
                beforeMode: snapshot.mode, afterMode: snapshot.mode
            )
        }
    }

    private func noChange(_ snapshot: Snapshot) -> CommandDiscoveryHookPlan {
        CommandDiscoveryHookPlan(
            before: snapshot.bytes, after: snapshot.bytes, changed: false,
            summary: "Ask Key's \(format.name) discovery command hook is already installed.",
            format: format, beforeMode: snapshot.mode, afterMode: snapshot.mode
        )
    }
}
