import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func createTextCredential(
        _ input: TextCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        return try performCredentialCreation(using: authenticator) {
        let key = try requireKey()
        let prepared = try preparedRecord(from: input, id: UUID().uuidString, key: key, existing: nil)
        try store.insertCredential(prepared)
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
        }
    }

    public func updateCredentialPermission(
        id: String,
        permission: CredentialPermission,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.permission = permission.rawValue
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

    public func updateCredentialMetadata(
        id: String,
        name: String,
        usageInstructions: String,
        groupName: String?,
        permission: CredentialPermission,
        expiresAt: Date?,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let displayName = try CredentialName.displayName(from: name)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        try CredentialFieldValidation.usageInstructions(usageInstructions)
        let group = try CredentialName.optionalDisplayName(groupName)
        try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            if let conflict = try store.fetchCredentialIncludingRecycled(nameIndex: nameIndex),
               conflict.id != id {
                throw VaultError.credentialNameConflict(displayName)
            }
            existing.nameIndex = nameIndex
            existing.encryptedDisplayName = try VaultCrypto.encrypt(displayName, using: key)
            existing.encryptedUsageInstructions = try VaultCrypto.encrypt(usageInstructions, using: key)
            existing.encryptedGroupName = try group.map { try VaultCrypto.encrypt($0, using: key) }
            existing.permission = permission.rawValue
            existing.expiresAt = expiresAt.map { sharedDateFormatter.string(from: $0) }
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
        }
    }

    public func listTextCredentials() throws -> [ManagedTextCredential] {
        try requireManagementSession()
        let key = try requireKey()
        return try store.fetchAllCredentials()
            .map { try managedCredential(from: $0, key: key, includeSecrets: false) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listCredentialExpirySnapshots() throws -> [CredentialExpirySnapshot] {
        try store.fetchAllCredentials().map { record in
            CredentialExpirySnapshot(
                id: record.id,
                expiresAt: try record.expiresAt.map { try parseExpiry($0) }
            )
        }
    }

    public func storedCredentialCount() throws -> Int {
        try credentialCountForBootstrap()
    }

    public func revealTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        let key = try requireKey()
        guard let record = try store.fetchCredential(id: id) else {
            throw VaultError.credentialNotFound(id)
        }
        return try managedCredential(from: record, key: key, includeSecrets: true)
    }

    public func updateTextCredential(
        id: String,
        _ input: TextCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let prepared = try performCredentialMutation(id: id) {
            guard let existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            let prepared = try preparedRecord(from: input, id: existing.id, key: key, existing: existing)
            try store.updateCredential(prepared)
            return prepared
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    public func deleteTextCredential(
        id: String,
        using authenticator: ManagementAuthenticator
    ) throws {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        _ = try requireKey()
        try performCredentialMutation(id: id) {
            try store.recycleCredential(id: id, deletedAt: sharedDateFormatter.string(from: currentDate))
        }
    }

    func performCredentialMutation<T>(id: String, _ mutation: () throws -> T) throws -> T {
        let deliveryManager = try fileDeliveryManager.get()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let result = try mutation()
        brokerRequests.cancelPending(credentialID: id)
        approvalRequests.cancelPending(credentialID: id)
        deliveryManager.revoke(credentialID: id)
        notifySnapshotRelevantChange()
        return result
    }
}
