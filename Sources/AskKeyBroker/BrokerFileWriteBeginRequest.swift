import Foundation

public struct BrokerFileWriteBeginRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let originalFilename: String
    public let expectedByteCount: Int

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        originalFilename: String,
        expectedByteCount: Int
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.originalFilename = originalFilename
        self.expectedByteCount = expectedByteCount
    }
}
