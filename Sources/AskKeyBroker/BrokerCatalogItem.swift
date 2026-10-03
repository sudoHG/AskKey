import Foundation

public struct BrokerCatalogItem: Codable, Equatable, Sendable {
    public let credentialID: String?
    public let components: [BrokerCatalogComponent]?
    public let name: String
    public let payloadKind: BrokerCatalogPayloadKind
    public let usageInstructions: String
    public let environmentVariable: String?
    public let expired: Bool

    public init(credentialID: String? = nil, name: String, payloadKind: BrokerCatalogPayloadKind, usageInstructions: String, environmentVariable: String?, expired: Bool, components: [BrokerCatalogComponent]? = nil) {
        self.credentialID = credentialID
        self.components = components
        self.name = name
        self.payloadKind = payloadKind
        self.usageInstructions = usageInstructions
        self.environmentVariable = environmentVariable
        self.expired = expired
    }
}
