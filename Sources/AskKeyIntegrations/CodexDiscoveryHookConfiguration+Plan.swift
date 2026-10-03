import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    /// Returns a plan without writing either the hooks file or a backup.
    public func preview() throws -> CodexDiscoveryHookPlan {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let snapshot = try readHooksSnapshot()
        let document = try parseDocument(snapshot?.bytes ?? Data())
        let matches = try matchingHookGroups(in: document)
        try validateOwnHook(matches)

        if let own = matches.first {
            let expected = Self.expectedHookGroup
            guard own.eventName == "PreToolUse",
                  jsonEqual(own.group, expected) else {
                throw CodexDiscoveryHookConfigurationError.customHookMismatch
            }
            return CodexDiscoveryHookPlan(
                before: snapshot?.bytes,
                after: snapshot?.bytes,
                changed: false,
                summary: "Ask Key's Codex discovery hook is already installed.",
                beforeMode: snapshot?.mode,
                afterMode: snapshot?.mode ?? 0o600
            )
        }

        var next = document
        try appendExpectedHook(to: &next)
        let after = try serializeDocument(next)
        let afterMode = snapshot?.mode ?? 0o600
        return CodexDiscoveryHookPlan(
            before: snapshot?.bytes,
            after: after,
            changed: true,
            summary: "Add Ask Key's Codex discovery hook.",
            beforeMode: snapshot?.mode,
            afterMode: afterMode
        )
    }
}
