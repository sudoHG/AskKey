import Darwin
import Foundation

public struct CommandDiscoveryHookPlan: Equatable, Sendable {
    public let before: Data?
    public let after: Data?
    public let changed: Bool
    public let summary: String
    public let format: CommandDiscoveryHookFormat

    let beforeMode: UInt32?
    let afterMode: UInt32

    init(
        before: Data?, after: Data?, changed: Bool, summary: String,
        format: CommandDiscoveryHookFormat, beforeMode: UInt32?, afterMode: UInt32
    ) {
        self.before = before
        self.after = after
        self.changed = changed
        self.summary = summary
        self.format = format
        self.beforeMode = beforeMode
        self.afterMode = afterMode
    }

    public var redactedDescription: String { summary }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.before == rhs.before && lhs.after == rhs.after && lhs.changed == rhs.changed
            && lhs.summary == rhs.summary && lhs.format == rhs.format
            && lhs.beforeMode == rhs.beforeMode && lhs.afterMode == rhs.afterMode
    }
}
