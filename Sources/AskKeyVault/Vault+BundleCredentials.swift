import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    public func createBundleCredential(
        _ input: BundleCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        return try performCredentialCreation(using: authenticator) {
        let key = try requireKey()
        let prepared = try preparedBundleRecord(
            from: input,
            id: UUID().uuidString,
            key: key,
            existing: nil
        )
        try store.insertCredential(prepared)
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
        }
    }

    public func updateBundleCredential(
        id: String,
        _ input: BundleCredentialInput,
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let prepared = try performCredentialMutation(id: id) {
            guard let existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            let prepared = try preparedBundleRecord(from: input, id: id, key: key, existing: existing)
            try store.updateCredential(prepared)
            return prepared
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }

    /// Replaces imported material without reconstructing redacted management metadata.
    public func replaceImportedBundleCredential(
        id: String,
        components: [CredentialComponentInput],
        using authenticator: ManagementAuthenticator
    ) throws -> ManagedTextCredential {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let key = try requireKey()
        let validated = try CredentialBundleValidator.validatedComponents(components)
        let prepared = try performCredentialMutation(id: id) {
            guard var existing = try store.fetchCredential(id: id) else {
                throw VaultError.credentialNotFound(id)
            }
            existing.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(validated), using: key)
            existing.payloadKind = CredentialPayloadKind.bundle.rawValue
            existing.encryptedEnvironmentVariable = nil
            existing.encryptedOriginalFilename = nil
            existing.byteSize = nil
            existing.contentDigest = nil
            existing.updatedAt = sharedDateFormatter.string(from: currentDate)
            try store.updateCredential(existing)
            return existing
        }
        return try managedCredential(from: prepared, key: key, includeSecrets: false)
    }
}
