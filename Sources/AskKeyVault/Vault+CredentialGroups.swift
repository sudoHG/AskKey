import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    static var credentialGroupsConfigKey: String { "credential_groups" }

    public func updateCredentialGroup(
        id: String,
        groupName: String?,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let group = try CredentialName.optionalDisplayName(groupName)
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.encryptedGroupName = try group.map { try VaultCrypto.encrypt($0, using: key) }
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

    public func listCredentialGroups() throws -> [String] {
        try requireManagementSession()
        let key = try requireKey()
        var groups = Set(try storedCredentialGroups(key: key))
        for record in try (store.fetchAllCredentials() + store.fetchRecycledCredentials()) {
            if let encrypted = record.encryptedGroupName {
                groups.insert(try VaultCrypto.decrypt(encrypted, using: key))
            }
        }
        return groups.sorted()
    }

    public func createCredentialGroup(
        _ rawName: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let name = try CredentialName.displayName(from: rawName)
        var groups = Set(try storedCredentialGroups(key: key))
        groups.insert(name)
        try persistCredentialGroups(groups.sorted(), key: key)
        notifySnapshotRelevantChange()
    }

    public func deleteCredentialGroup(
        _ rawName: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let name = try CredentialName.displayName(from: rawName)
        let deliveryManager = try fileDeliveryManager.get()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        var groups = Set(try storedCredentialGroups(key: key))
        groups.remove(name)
        let matchingIDs = try (store.fetchAllCredentials() + store.fetchRecycledCredentials())
            .compactMap { record -> String? in
                guard let encrypted = record.encryptedGroupName,
                      try VaultCrypto.decrypt(encrypted, using: key) == name else { return nil }
                return record.id
            }
        let encrypted = try encryptedCredentialGroups(groups.sorted(), key: key)
        try store.replaceCredentialGroupsConfig(
            key: Self.credentialGroupsConfigKey,
            value: encrypted,
            clearingCredentialIDs: matchingIDs,
            updatedAt: sharedDateFormatter.string(from: currentDate)
        )
        for id in matchingIDs {
            brokerRequests.cancelPending(credentialID: id)
            approvalRequests.cancelPending(credentialID: id)
            deliveryManager.revoke(credentialID: id)
        }
        notifySnapshotRelevantChange()
    }

    func storedCredentialGroups(key: SymmetricKey) throws -> [String] {
        guard let value = try store.configValue(key: Self.credentialGroupsConfigKey) else { return [] }
        guard let encrypted = Data(base64Encoded: value) else {
            throw VaultError.databaseError("Credential groups are invalid.")
        }
        return try JSONDecoder().decode(
            [String].self,
            from: VaultCrypto.decryptData(encrypted, using: key)
        )
    }

    private func persistCredentialGroups(_ groups: [String], key: SymmetricKey) throws {
        try store.setConfigValue(
            key: Self.credentialGroupsConfigKey,
            value: try encryptedCredentialGroups(groups, key: key)
        )
    }

    func encryptedCredentialGroups(_ groups: [String], key: SymmetricKey) throws -> String {
        try VaultCrypto.encrypt(JSONEncoder().encode(groups), using: key).base64EncodedString()
    }
}
