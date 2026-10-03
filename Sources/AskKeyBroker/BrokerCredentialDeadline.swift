import Foundation

/// Vault-derived credential expiry. Agent request fields never supply this value.
public enum BrokerCredentialDeadline: Equatable, Sendable {
    case none
    case expiresAt(Date)
}

extension BrokerCredentialDeadline {
    var date: Date? {
        switch self {
        case .none: return nil
        case .expiresAt(let date): return date
        }
    }
}
