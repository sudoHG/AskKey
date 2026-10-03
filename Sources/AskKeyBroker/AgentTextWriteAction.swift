import Foundation

public enum AgentTextWriteAction: Codable, Equatable, Sendable {
    case createBundle(name: String, components: [BrokerCredentialComponentInput])
    case modifyBundle(name: String, changes: [BrokerCredentialComponentChange])
    case create(name: String, value: String)
    case modify(name: String, value: String)
    case delete(name: String)
}
