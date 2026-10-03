import Foundation

public enum BrokerProviderError: Error, Equatable {
    case agentAccessPaused
    case requestRejected
    case invalidRequest
    case requestNotFound
    case resourceExhausted
}
