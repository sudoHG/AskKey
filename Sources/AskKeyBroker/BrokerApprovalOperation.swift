import Foundation

public enum BrokerApprovalOperation: String, Codable, Equatable, Sendable {
    case read
    case create
    case modify
    case delete
    case organize
}
