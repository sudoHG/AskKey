import Foundation

public struct AgentTextWriteSubmission: Codable, Equatable, Sendable {
    public let operationID: String
    public let requestID: String
    public let capability: String
    public let state: BrokerRequestState
    public let retryCount: Int

    public init(operationID: String, requestID: String, capability: String, state: BrokerRequestState, retryCount: Int) {
        self.operationID = operationID
        self.requestID = requestID
        self.capability = capability
        self.state = state
        self.retryCount = retryCount
    }
}
