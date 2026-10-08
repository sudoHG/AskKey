import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    /// Empty groups and groups with any active visible member; no member counts.
    public func brokerCredentialGroups(cancellation: BrokerCancellation? = nil) throws -> [String] {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        try cancellation?.check()
        let key = try requireKey()
        let snapshot = try store.agentOrganizationSnapshot(key: key)
        let assignments = try snapshot.assignments(key: key)
        let names = Set(snapshot.storedGroups).union(assignments.values)
        let visible = names.filter { name in
            let members = snapshot.records.filter { assignments[$0.id].map(CredentialName.normalized) == CredentialName.normalized(name) }
            return members.isEmpty || members.contains { $0.deletedAt == nil && $0.permission != CredentialPermission.hidden.rawValue }
        }.sorted()
        try cancellation?.check()
        return visible
    }
}
