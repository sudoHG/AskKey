import Foundation

public struct BrokerHealth: Codable, Equatable, Sendable {
    public let version: Int
    public let status: String

    public init(version: Int, status: String) {
        self.version = version
        self.status = status
    }
}
