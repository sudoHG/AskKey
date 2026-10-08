import CryptoKit
import Foundation
import AskKeyBroker

struct FrozenAgentOrganization {
    let request: AgentTextWriteRequest
    let digest: String
    let approvalRequest: BrokerApprovalOperationRequest
    let credentialExpiresAt: Date?
    let before: [CredentialRecord]
    let after: [CredentialRecord]
    let movedCredentialIDs: Set<String>
    let groups: [AgentOrganizationGroupState]
    let finalGroupNames: [String]
    let summary: BrokerOrganizationSummary
}

struct AgentOrganizationGroupState: Codable, Equatable {
    let normalizedName: String
    let names: [String]
    let storedNames: [String]
    let memberIDs: [String]
}

struct AgentOrganizationSnapshot {
    let records: [CredentialRecord]
    let storedGroups: [String]

    static func storedGroups(_ value: String?, key: SymmetricKey) throws -> [String] {
        guard let value else { return [] }
        guard let encrypted = Data(base64Encoded: value) else {
            throw VaultError.databaseError("Credential groups are invalid.")
        }
        return try JSONDecoder().decode([String].self, from: VaultCrypto.decryptData(encrypted, using: key))
    }

    func assignments(key: SymmetricKey) throws -> [String: String] {
        var result: [String: String] = [:]
        for record in records {
            if let encrypted = record.encryptedGroupName {
                result[record.id] = try VaultCrypto.decrypt(encrypted, using: key)
            }
        }
        return result
    }

    func groupStates(names: Set<String>, key: SymmetricKey) throws -> [AgentOrganizationGroupState] {
        let assignments = try assignments(key: key)
        let allNames = Set(storedGroups).union(assignments.values)
        return names.sorted().map { normalized in
            .init(normalizedName: normalized,
                names: allNames.filter { CredentialName.normalized($0) == normalized }.sorted(),
                storedNames: storedGroups.filter { CredentialName.normalized($0) == normalized }.sorted(),
                memberIDs: assignments.filter { CredentialName.normalized($0.value) == normalized }.keys.sorted())
        }
    }
}
