import Foundation

extension Vault {
    /// Separate from agent-access policy recovery: management stays available.
    public var componentMetadataIssue: ComponentMetadataUpgradeError? {
        (try? store)?.componentMetadataIssue
    }
}
