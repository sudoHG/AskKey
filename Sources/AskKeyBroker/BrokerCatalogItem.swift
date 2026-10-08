import Foundation

public struct BrokerCatalogItem: Codable, Equatable, Sendable {
    public let credentialID: String?
    public let components: [BrokerCatalogComponent]?
    public let name: String
    public let payloadKind: BrokerCatalogPayloadKind
    public let usageInstructions: String
    public let group: String?
    public let environmentVariable: String?
    public let expired: Bool

    public init(credentialID: String? = nil, name: String, payloadKind: BrokerCatalogPayloadKind, usageInstructions: String, environmentVariable: String?, expired: Bool, components: [BrokerCatalogComponent]? = nil, group: String? = nil) {
        self.credentialID = credentialID
        self.components = components
        self.name = name
        self.payloadKind = payloadKind
        self.usageInstructions = usageInstructions
        self.group = group
        self.environmentVariable = environmentVariable
        self.expired = expired
    }

    private enum CodingKeys: String, CodingKey {
        case credentialID, components, name, payloadKind, usageInstructions, group, environmentVariable, expired
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(credentialID, forKey: .credentialID)
        try container.encodeIfPresent(components, forKey: .components)
        try container.encode(name, forKey: .name)
        try container.encode(payloadKind, forKey: .payloadKind)
        try container.encode(usageInstructions, forKey: .usageInstructions)
        try container.encode(group, forKey: .group)
        try container.encodeIfPresent(environmentVariable, forKey: .environmentVariable)
        try container.encode(expired, forKey: .expired)
    }
}
