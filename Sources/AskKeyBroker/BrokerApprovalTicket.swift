import Foundation

public struct BrokerApprovalTicket: Codable, Equatable, Sendable {
    public let requestID: String
    public let capability: String
    public let state: BrokerRequestState
    public let retryCount: Int

    public init(requestID: String, capability: String, state: BrokerRequestState, retryCount: Int) {
        self.requestID = requestID
        self.capability = capability
        self.state = state
        self.retryCount = retryCount
    }
}
