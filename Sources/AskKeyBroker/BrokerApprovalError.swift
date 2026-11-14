import Foundation

public enum BrokerApprovalError: Error, Equatable {
    case invalidRequest
    case payloadMismatch
    case capacityReached
    case requestNotFound
    case authenticationFailed
    case invalidDecision
    case alreadyConsumed
    case commitInProgress
    case agentAccessPaused
    /// A local decision lost to a paired approver's decision, which moved the
    /// request out of pending first. Not a failure; show no error.
    case decidedElsewhere
}
