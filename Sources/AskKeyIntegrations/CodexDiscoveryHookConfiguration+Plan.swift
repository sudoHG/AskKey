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

        if matches.count == Self.expectedEvents.count && matches.allSatisfy({ !$0.legacy }) {
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
        try appendExpectedHook(to: &next, matches: matches)
        let after = try serializeDocument(next)
        let afterMode = snapshot?.mode ?? 0o600
        return CodexDiscoveryHookPlan(
            before: snapshot?.bytes,
            after: after,
            changed: true,
            summary: "Install Ask Key's Codex command discovery hooks.",
            beforeMode: snapshot?.mode,
            afterMode: afterMode
        )
    }
}
