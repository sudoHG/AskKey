import Foundation

public enum BrokerApprovalDecision: Equatable, Sendable {
    case once
    case deny
    case timedAllow(duration: TimeInterval?)
    case timedAllowGroup(duration: TimeInterval?)

    /// Outer nil denotes a non-timed decision; inner nil uses the configured duration.
    package var timedDuration: TimeInterval?? {
        switch self {
        case .timedAllow(let duration), .timedAllowGroup(let duration): return .some(duration)
        case .once, .deny: return nil
        }
    }
}
