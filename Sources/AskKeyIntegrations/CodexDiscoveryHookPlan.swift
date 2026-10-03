import Darwin
import Foundation

/// The reviewed, user-facing change to Codex's PreToolUse hook configuration.
///
/// `before` and `after` are retained for an optimistic-concurrency check. They
/// are opaque bytes to callers; `summary` is the only safe text intended for a
/// confirmation screen and describes Ask Key's hook only.
public struct CodexDiscoveryHookPlan: Equatable, Sendable {
    public let before: Data?
    public let after: Data?
    public let changed: Bool
    public let summary: String

    let beforeMode: UInt32?
    let afterMode: UInt32

    init(
        before: Data?,
        after: Data?,
        changed: Bool,
        summary: String,
        beforeMode: UInt32?,
        afterMode: UInt32
    ) {
        self.before = before
        self.after = after
        self.changed = changed
        self.summary = summary
        self.beforeMode = beforeMode
        self.afterMode = afterMode
    }

    /// Safe text for a confirmation screen. It never includes other hooks.
    public var redactedDescription: String { summary }

    public static func == (
        lhs: CodexDiscoveryHookPlan,
        rhs: CodexDiscoveryHookPlan
    ) -> Bool {
        lhs.before == rhs.before
            && lhs.after == rhs.after
            && lhs.changed == rhs.changed
            && lhs.summary == rhs.summary
            && lhs.beforeMode == rhs.beforeMode
            && lhs.afterMode == rhs.afterMode
    }
}
