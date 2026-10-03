import CryptoKit
import Darwin
import Foundation

public struct BrokerFileUploadTicket: Equatable, Sendable {
    public let uploadID: String
    public let capability: String
}

extension BrokerFileUploadTicket: Codable {}
