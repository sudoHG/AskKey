import CryptoKit
import Darwin
import Foundation

public struct BrokerFrozenFile: Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let previousDigest: String?
    public let originalFilename: String
    public let bytes: Data
    public let byteCount: Int
    public let digest: String
    public let approvalRequestID: String?
    public let approvalCapability: String?

    public var approvalPayloadDigest: String {
        let fields = [operationID, credentialID, targetID, operation.rawValue,
            originalFilename, String(byteCount), previousDigest ?? "none", digest]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        previousDigest: String?,
        originalFilename: String,
        bytes: Data,
        byteCount: Int,
        digest: String,
        approvalRequestID: String? = nil,
        approvalCapability: String? = nil
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.previousDigest = previousDigest
        self.originalFilename = originalFilename
        self.bytes = bytes
        self.byteCount = byteCount
        self.digest = digest
        self.approvalRequestID = approvalRequestID
        self.approvalCapability = approvalCapability
    }
}
