import Foundation

public enum BrokerApprovalDecision: Equatable, Sendable {
    case once
    case deny
    case timedAllow(duration: TimeInterval?)
}
