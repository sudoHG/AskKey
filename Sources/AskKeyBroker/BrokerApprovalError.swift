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
}
