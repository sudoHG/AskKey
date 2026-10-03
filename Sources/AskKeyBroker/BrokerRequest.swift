import Foundation

public struct BrokerRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let method: String
    public let requestID: String?
    public let capability: String?
    public let textRun: BrokerTextRunRequest?
    public let fileWrite: BrokerFileWriteRequest?
    public let operationID: String?
    public let textWrite: AgentTextWriteRequest?

    public init(
        version: Int,
        method: String,
        requestID: String? = nil,
        capability: String? = nil,
        textRun: BrokerTextRunRequest? = nil,
        fileWrite: BrokerFileWriteRequest? = nil,
        operationID: String? = nil,
        textWrite: AgentTextWriteRequest? = nil
    ) {
        self.version = version
        self.method = method
        self.requestID = requestID
        self.capability = capability
        self.textRun = textRun
        self.fileWrite = fileWrite
        self.operationID = operationID
        self.textWrite = textWrite
    }
}
