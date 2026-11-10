import Foundation
import Security

/// Decides whether this process may create the CloudKit transport (ADR 0013
/// → CloudKit layout). Creating a `CKContainer` terminates an App that lacks
/// the entitlement, so Debug, E2E and CI builds never create one: only a
/// build whose Info.plist declares the container (`CloudKitContainerIdentifier`,
/// written by the CloudKit option of `scripts/build-app.sh`) and whose signed
/// entitlements contain that container and the CloudKit service qualifies.
/// Every other build reports Devices as not configured and creates no
/// CloudKit object.
package enum CloudKitGate {
    package static let infoPlistKey = "CloudKitContainerIdentifier"
    package static let containerEntitlement = "com.apple.developer.icloud-container-identifiers"
    package static let servicesEntitlement = "com.apple.developer.icloud-services"

    package enum Decision: Equatable, Sendable {
        case configured(containerIdentifier: String)
        case notConfigured

        package var containerIdentifier: String? {
            if case .configured(let identifier) = self { return identifier }
            return nil
        }
    }

    /// The decision for an Info.plist and a reader of this process's signed
    /// entitlements. The reader runs only when the Info.plist declares a
    /// container.
    package static func decide(infoDictionary: [String: Any], entitlement: (String) -> Any?) -> Decision {
        guard let declared = infoDictionary[infoPlistKey] as? String, !declared.isEmpty else { return .notConfigured }
        guard let containers = entitlement(containerEntitlement) as? [String], containers.contains(declared),
              let services = entitlement(servicesEntitlement) as? [String], services.contains("CloudKit") else {
            return .notConfigured
        }
        return .configured(containerIdentifier: declared)
    }

    /// The decision for this process: its main bundle's Info.plist and its
    /// own code signature's entitlements.
    package static func currentProcessDecision() -> Decision {
        decide(infoDictionary: Bundle.main.infoDictionary ?? [:], entitlement: signedEntitlement)
    }

    private static func signedEntitlement(_ key: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, key as CFString, nil)
    }
}
