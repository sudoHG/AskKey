import Foundation

public struct BrokerFileWriteChunkRequest: Codable, Equatable, Sendable {
    public let uploadID: String
    public let capability: String
    public let offset: Int
    public let bytes: Data

    public init(uploadID: String, capability: String, offset: Int, bytes: Data) {
        self.uploadID = uploadID
        self.capability = capability
        self.offset = offset
        self.bytes = bytes
    }
}
