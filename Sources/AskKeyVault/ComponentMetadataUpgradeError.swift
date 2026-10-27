import Foundation

/// Actionable without disclosing values, filenames or delivery mappings.
public struct ComponentMetadataUpgradeError: Error, Equatable, LocalizedError, Sendable {
    public enum Reason: Sendable { case backfill, integrity }
    public let reason: Reason
    public let credentialNames: [String]

    public var errorDescription: String? {
        let names = credentialNames.map { String(reflecting: $0) }.joined(separator: ", ")
        switch reason {
        case .backfill:
            return "Component metadata could not be upgraded for: \(names). Credential management remains available. Fix or delete these credentials, then reopen Ask Key. Agent access stays off until the upgrade completes."
        case .integrity:
            return "Component metadata integrity could not be verified\(names.isEmpty ? "" : " for: " + names). Credential management remains available. Review the affected credentials and restore a trusted library or contact support, then reopen Ask Key. Agent access stays off until integrity is restored."
        }
    }
}
