import Foundation

public struct BrokerApprovalOperationRequest: Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let targetID: String
    public let operation: BrokerApprovalOperation
    public let payloadDigest: String
    public let retransmissionDigest: String?
    public let credentialName: String?
    public let callerName: String?
    public let callerPurpose: String?

    public init(
        operationID: String,
        credentialID: String,
        targetID: String,
        operation: BrokerApprovalOperation,
        payloadDigest: String,
        credentialName: String? = nil,
        callerName: String? = nil,
        callerPurpose: String? = nil,
        retransmissionDigest: String? = nil
    ) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.targetID = targetID
        self.operation = operation
        self.payloadDigest = payloadDigest
        self.retransmissionDigest = retransmissionDigest
        self.credentialName = credentialName
        self.callerName = callerName
        self.callerPurpose = callerPurpose
    }
}

extension BrokerApprovalOperationRequest {
    func matchesForConsumption(_ other: BrokerApprovalOperationRequest) -> Bool {
        operationID == other.operationID
            && credentialID == other.credentialID
            && targetID == other.targetID
            && operation == other.operation
            && credentialName == other.credentialName
            && callerName == other.callerName
            && callerPurpose == other.callerPurpose
            && retransmissionDigest == other.retransmissionDigest
            && constantTimeEqual(payloadDigest, other.payloadDigest)
    }

    func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
