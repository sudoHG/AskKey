import Foundation

public enum BrokerCatalogPayloadKind: String, Codable, Equatable, Sendable {
    case text
    case file
}
