import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    public func hasExpectedHook() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let definition = try makeDefinition()
        guard let snapshot = try readSnapshot(at: hooksURL, checkParent: true) else { return false }
        return try hasExpectedHook(in: snapshot.bytes, definition: definition)
    }
    private func hasExpectedHook(in bytes: Data, definition: Definition) throws -> Bool {
        let existing = try object(bytes, error: .invalidHooksFile)
        switch format {
        case .claudeMerged:
            _ = try CommandHookJSON.parse(bytes)
            return try claudeMatches(in: existing, definition: definition).count == definition.groups.count
        case .grokOwned:
            if jsonEqual(existing, definition.root) { return true }
            if containsOwnLike(in: existing, commands: definition.commands) {
                throw Error.customHookMismatch
            }
            throw Error.ownedFileConflict
        case .cursorMerged:
            let found = try cursorMatches(in: existing, definition: definition)
            try validate(found, expected: definition.groups)
            return found.filter(\.exact).count == definition.groups.values.reduce(0) { $0 + $1.count }
        }
    }
}
