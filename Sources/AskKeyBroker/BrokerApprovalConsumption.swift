import Foundation

public struct BrokerApprovalConsumption: Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let operationRequest: BrokerApprovalOperationRequest

    public init(requestID: String, capability: String, operationRequest: BrokerApprovalOperationRequest) {
        self.requestID = requestID
        self.capability = capability
        self.operationRequest = operationRequest
    }
}
