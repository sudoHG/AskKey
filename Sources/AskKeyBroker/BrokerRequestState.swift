import Foundation

public enum BrokerRequestState: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case denied
    case cancelled
    case expired
    case completed
    case consumed
    case outcomeUnknown = "outcome_unknown"
}
