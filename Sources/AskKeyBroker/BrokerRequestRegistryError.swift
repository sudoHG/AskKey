import Foundation

public enum BrokerRequestRegistryError: Error, Equatable {
    case capacityReached
    case duplicateRequest
    case agentAccessPaused
}
