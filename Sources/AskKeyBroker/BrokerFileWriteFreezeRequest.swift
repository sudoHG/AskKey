import Foundation

public struct BrokerFileWriteFreezeRequest: Codable, Equatable, Sendable {
    public let uploadID: String
    public let capability: String

    public init(uploadID: String, capability: String) {
        self.uploadID = uploadID
        self.capability = capability
    }
}
