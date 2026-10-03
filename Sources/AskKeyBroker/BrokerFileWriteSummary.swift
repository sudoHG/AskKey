import CryptoKit
import Darwin
import Foundation

public struct BrokerFileWriteSummary: Equatable, Sendable {
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let payloadKind: BrokerCatalogPayloadKind
    public let originalFilename: String
    public let byteCount: Int
    public let previousDigest: String?
    public let digest: String
    public let payloadMasked: Bool
    public let state: BrokerRequestState
}
