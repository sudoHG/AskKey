import Foundation

public enum AgentTextWriteAction: Codable, Equatable, Sendable {
    case organize([BrokerOrganizationOperation])
    case createBundle(name: String, components: [BrokerCredentialComponentInput], usageInstructions: String? = nil, group: String? = nil)
    case modifyBundle(name: String, changes: [BrokerCredentialComponentChange] = [], usageInstructions: String? = nil, group: BrokerCredentialGroupChange? = nil)
    case create(name: String, value: String)
    case modify(name: String, value: String)
    case delete(name: String)
}
