import Foundation

public enum BrokerResponse: Codable, Equatable, Sendable {
    case success(BrokerPayload)
    case failure(BrokerErrorCode)
}
