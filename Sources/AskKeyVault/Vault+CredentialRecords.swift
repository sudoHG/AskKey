import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    func preparedRecord(
        from input: TextCredentialInput,
        id: String,
        key: SymmetricKey,
        existing: CredentialRecord?
    ) throws -> CredentialRecord {
        let displayName = try CredentialName.displayName(from: input.name)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        if let conflict = try store.fetchCredentialIncludingRecycled(nameIndex: nameIndex), conflict.id != id {
            throw VaultError.credentialNameConflict(displayName)
        }
        let group = try CredentialName.optionalDisplayName(input.groupName)
        try CredentialFieldValidation.usageInstructions(input.usageInstructions)
        let environmentVariable = try optionalEnvironmentVariable(input.environmentVariable)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: nameIndex,
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: try VaultCrypto.encrypt(input.value, using: key),
            encryptedUsageInstructions: try VaultCrypto.encrypt(input.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(input.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: try environmentVariable.map { try VaultCrypto.encrypt($0, using: key) },
            payloadKind: CredentialPayloadKind.text.rawValue,
            permission: input.permission.rawValue,
            expiresAt: input.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            encryptedOriginalFilename: nil,
            byteSize: nil,
            contentDigest: nil,
            deletedAt: existing?.deletedAt
        )
    }

    func preparedBundleRecord(
        from input: BundleCredentialInput,
        id: String,
        key: SymmetricKey,
        existing: CredentialRecord?
    ) throws -> CredentialRecord {
        let displayName = try CredentialName.displayName(from: input.name)
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        if let conflict = try store.fetchCredentialIncludingRecycled(nameIndex: nameIndex), conflict.id != id {
            throw VaultError.credentialNameConflict(displayName)
        }
        let components = try CredentialBundleValidator.validatedComponents(input.components)
        let group = try CredentialName.optionalDisplayName(input.groupName)
        try CredentialFieldValidation.usageInstructions(input.usageInstructions)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: nameIndex,
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key),
            encryptedUsageInstructions: try VaultCrypto.encrypt(input.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(input.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: nil,
            payloadKind: CredentialPayloadKind.bundle.rawValue,
            permission: input.permission.rawValue,
            expiresAt: input.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            encryptedOriginalFilename: nil,
            byteSize: nil,
            contentDigest: nil,
            deletedAt: existing?.deletedAt
        )
    }

    /// Converts legacy single-material records into the same whole-credential
    /// representation used by bundles, without exposing their values to Broker.
    func credentialComponents(from record: CredentialRecord, key: SymmetricKey) throws -> [CredentialComponentInput] {
        let components: [CredentialComponentInput]
        switch CredentialPayloadKind(rawValue: record.payloadKind) {
        case .bundle:
            components = try JSONDecoder().decode([CredentialComponentInput].self,
                from: VaultCrypto.decryptData(record.encryptedPayload, using: key))
        case .text:
            let variable = try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) }
            components = [.init(name: legacyComponentName(mapping: variable, fallback: "VALUE"),
                value: .text(try VaultCrypto.decrypt(record.encryptedPayload, using: key)),
                delivery: variable.map { .environmentVariable($0) } ?? .none)]
        case .file:
            let bytes = try VaultCrypto.decryptData(record.encryptedPayload, using: key)
            guard let digest = record.contentDigest, Data(SHA256.hash(data: bytes)) == digest,
                  let filename = record.encryptedOriginalFilename else {
                throw VaultError.invalidFileCredential(.digestMismatch)
            }
            let variable = try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) }
            components = [.init(name: legacyComponentName(mapping: variable, fallback: "FILE"),
                value: .file(filename: try VaultCrypto.decrypt(filename, using: key), bytes: bytes),
                delivery: variable.map { .temporaryFile($0) } ?? .none)]
        case nil:
            throw VaultError.databaseError("Credential has an unknown payload kind.")
        }
        return try CredentialBundleValidator.validatedComponents(components)
    }

    private func legacyComponentName(mapping: String?, fallback: String) -> String {
        // A delivery mapping has its own byte limit; it is not necessarily a valid display name.
        guard let mapping, let name = try? CredentialName.displayName(from: mapping) else { return fallback }
        return name
    }

    func managedCredential(
        from record: CredentialRecord,
        key: SymmetricKey,
        includeSecrets: Bool
    ) throws -> ManagedTextCredential {
        let permission = CredentialPermission(rawValue: record.permission) ?? .ask
        let payloadKind = CredentialPayloadKind(rawValue: record.payloadKind) ?? .text
        let digestHex = record.contentDigest.map { $0.map { String(format: "%02x", $0) }.joined() }
        var value: String?
        var fileBytes: Data?
        var originalFilename: String?
        var privateNotes: String?
        var components: [ManagedCredentialComponent] = []
        if payloadKind == .bundle {
            let decoded = try JSONDecoder().decode(
                [CredentialComponentInput].self,
                from: VaultCrypto.decryptData(record.encryptedPayload, using: key)
            )
            components = decoded.map {
                ManagedCredentialComponent(
                    name: $0.name,
                    kind: $0.value.payloadKind,
                    value: includeSecrets ? $0.value : nil,
                    delivery: $0.delivery,
                    masked: $0.masked
                )
            }
        }
        if includeSecrets {
            privateNotes = try VaultCrypto.decrypt(record.encryptedPrivateNotes, using: key)
            if payloadKind == .file {
                let bytes = try VaultCrypto.decryptData(record.encryptedPayload, using: key)
                guard let expected = record.contentDigest, Data(SHA256.hash(data: bytes)) == expected else {
                    throw VaultError.invalidFileCredential(.digestMismatch)
                }
                fileBytes = bytes
                originalFilename = try record.encryptedOriginalFilename.map {
                    try VaultCrypto.decrypt($0, using: key)
                }
            } else if payloadKind == .text {
                value = try VaultCrypto.decrypt(record.encryptedPayload, using: key)
            }
        }
        return ManagedTextCredential(
            id: record.id,
            name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
            value: value,
            usageInstructions: try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key),
            privateNotes: privateNotes,
            groupName: try record.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            environmentVariable: try record.encryptedEnvironmentVariable.map { try VaultCrypto.decrypt($0, using: key) },
            permission: permission,
            expiresAt: try record.expiresAt.map { try parseExpiry($0) },
            payloadKind: payloadKind,
            originalFilename: originalFilename,
            byteSize: record.byteSize,
            contentDigest: digestHex,
            fileBytes: fileBytes,
            components: components,
            deletedAt: try record.deletedAt.map { try parseExpiry($0) }
        )
    }

    func optionalEnvironmentVariable(_ raw: String?) throws -> String? {
        try CredentialFieldValidation.optionalEnvironmentVariable(raw)
    }

    func parseExpiry(_ value: String) throws -> Date {
        guard let date = sharedDateFormatter.date(from: value) else {
            throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
        }
        return date
    }
}
