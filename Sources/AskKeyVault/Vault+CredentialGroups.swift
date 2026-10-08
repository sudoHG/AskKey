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
        return try credentialGroupNames(key: requireKey())
    }

    func credentialGroupNames(key: SymmetricKey) throws -> [String] {
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
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        _ = try store.editCredentialGroup(name, key: key, deleting: false,
            updatedAt: sharedDateFormatter.string(from: currentDate))
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
        let matchingIDs = try store.editCredentialGroup(name, key: key, deleting: true,
            updatedAt: sharedDateFormatter.string(from: currentDate))
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
}
