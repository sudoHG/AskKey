import Foundation

public struct AgentTextWriteRequest: Codable, Equatable, Sendable {
    public let operationID: String
    public let action: AgentTextWriteAction
    public let callerName: String?
    public let callerPurpose: String?

    public init(
        operationID: String,
        action: AgentTextWriteAction,
        callerName: String? = nil,
        callerPurpose: String? = nil
    ) {
        self.operationID = operationID
        self.action = action
        self.callerName = callerName
        self.callerPurpose = callerPurpose
    }
}
