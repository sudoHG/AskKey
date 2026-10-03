import Foundation

public struct AgentTextWriteResult: Codable, Equatable, Sendable {
    public let operationID: String
    public let credentialID: String
    public let state: BrokerRequestState

    public init(operationID: String, credentialID: String, state: BrokerRequestState = .completed) {
        self.operationID = operationID
        self.credentialID = credentialID
        self.state = state
    }
}
