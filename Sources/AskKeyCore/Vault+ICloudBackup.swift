import CryptoKit
import Foundation
import GRDB

public final class VaultICloudBackupRestoreTarget: ICloudBackupRestoreTarget {
    private let vault: Vault
    private let currentSettings: () throws -> ICloudBackupSettings
    private let applySettings: (ICloudBackupSettings) throws -> Void

    public init(
        vault: Vault,
        currentSettings: @escaping () throws -> ICloudBackupSettings,
        applySettings: @escaping (ICloudBackupSettings) throws -> Void
    ) throws {
        self.vault = vault
        self.currentSettings = currentSettings
        self.applySettings = applySettings
        try vault.recoverPendingICloudRestoreSettings(applySettings: applySettings)
    }

    public func restoreLibraryAtomically(
        with snapshot: ICloudBackupSnapshot,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws {
        try vault.restoreLibraryFromICloudBackup(
            snapshot,
            currentSettings: currentSettings,
            persistLocalSafetySnapshot: persistLocalSafetySnapshot,
            applySettings: applySettings
        )
    }

}

extension Vault {
    public func resetReadApprovalAuthenticationAfterRestore() {
        approvalRequests.resetReadAuthenticationToDefaultEnabled()
    }

    public func makeICloudBackupSnapshot(
        settings: ICloudBackupSettings
    ) throws -> ICloudBackupSnapshot {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try makeICloudBackupSnapshotWithinLifecycle(settings: settings)
    }

    /// One admission covers both reading the library and committing the cloud
    /// generation. Pause/erase wait for this operation before taking effect,
    /// and immediately reject any backup arriving after quiescing begins.
    public func backUpToICloud(
        using coordinator: ICloudBackupCoordinator,
        settings: ICloudBackupSettings,
        createdAt: Date = Date()
    ) throws -> ICloudBackupGeneration {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        return try coordinator.backUp(
            snapshot: makeICloudBackupSnapshotWithinLifecycle(settings: settings),
            createdAt: createdAt
        )
    }

    /// Restore already holds the exclusive lifecycle gate and needs a local
    /// safety snapshot even when Agent access was paused beforehand.
    private func makeICloudBackupSnapshotWithinLifecycle(
        settings: ICloudBackupSettings
    ) throws -> ICloudBackupSnapshot {
        let key = try requireKey()
        let records = try store.fetchAllCredentialsIncludingRecycled()
        let credentials = try records.map { record -> ICloudBackupCredential in
            guard let permission = CredentialPermission(rawValue: record.permission),
                  let kind = CredentialPayloadKind(rawValue: record.payloadKind) else {
                throw VaultError.databaseError("Credential backup metadata is invalid.")
            }
            let payload: ICloudBackupCredential.Payload
            switch kind {
            case .text:
                payload = .text(try VaultCrypto.decrypt(record.encryptedPayload, using: key))
            case .file:
                guard let encryptedFilename = record.encryptedOriginalFilename else {
                    throw VaultError.databaseError("File credential backup metadata is incomplete.")
                }
                payload = .file(
                    bytes: try VaultCrypto.decryptData(record.encryptedPayload, using: key),
                    originalFilename: try VaultCrypto.decrypt(encryptedFilename, using: key)
                )
            case .bundle:
                payload = .bundle(try VaultCrypto.decryptData(record.encryptedPayload, using: key))
            }
            let expiresAt: Date?
            if let value = record.expiresAt {
                guard let date = sharedDateFormatter.date(from: value) else {
                    throw VaultError.databaseError("Credential expiry is not a valid timestamp.")
                }
                expiresAt = date
            } else {
                expiresAt = nil
            }
            let deletedAt: Date?
            if let value = record.deletedAt {
                guard let date = CredentialFieldValidation.backupDeletionDate(from: value) else {
                    throw VaultError.databaseError("Credential deletion time is not a valid timestamp.")
                }
                deletedAt = date
            } else {
                deletedAt = nil
            }
            let displayName = try VaultCrypto.decrypt(record.encryptedDisplayName, using: key)
            let usageInstructions = try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key)
            let environmentVariable = try record.encryptedEnvironmentVariable.map {
                try VaultCrypto.decrypt($0, using: key)
            }
            _ = try CredentialName.displayName(from: displayName)
            try CredentialFieldValidation.usageInstructions(usageInstructions)
            if let environmentVariable {
                try CredentialFieldValidation.environmentVariable(environmentVariable)
            }
            return ICloudBackupCredential(
                id: record.id,
                displayName: displayName,
                payload: payload,
                usageInstructions: usageInstructions,
                privateNotes: try VaultCrypto.decrypt(record.encryptedPrivateNotes, using: key),
                groupName: try record.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
                environmentVariable: environmentVariable,
                permission: permission,
                expiresAt: expiresAt,
                deletedAt: deletedAt
            )
        }
        try credentials.forEach(CredentialFieldValidation.backupCredential)
        let groups = Set(try storedCredentialGroups(key: key))
            .union(credentials.compactMap(\.groupName)).sorted()
        return ICloudBackupSnapshot(
            credentials: credentials,
            groupNames: groups,
            settings: settings
        )
    }

    func makeEncryptedLocalSafetySnapshot(settings: ICloudBackupSettings) throws -> Data {
        try requireManagementSession()
        let key = try requireKey()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try VaultCrypto.encrypt(
            encoder.encode(try makeICloudBackupSnapshotWithinLifecycle(settings: settings)),
            using: key
        )
    }

    func restoreLibraryFromICloudBackup(
        _ snapshot: ICloudBackupSnapshot,
        currentSettings: () throws -> ICloudBackupSettings,
        persistLocalSafetySnapshot: (Data) throws -> Void,
        applySettings: (ICloudBackupSettings) throws -> Void,
        // Test-only crash seam after the transactional library/settings journal write.
        afterDatabaseReplace: () throws -> Void = {}
    ) throws {
        try requireManagementSession()
        guard snapshot.hasSupportedFormatVersion else {
            throw ICloudBackupError.invalidSnapshot
        }
        do {
            try snapshot.credentials.forEach(CredentialFieldValidation.backupCredential)
        } catch {
            throw ICloudBackupError.invalidSnapshot
        }
        let key = try requireKey()
        let now = sharedDateFormatter.string(from: currentDate)
        // Explicit groups are independent library contents, including groups
        // with no credentials. Validate before any safety snapshot or DB write.
        let groups: [String]
        do {
            groups = try Set(snapshot.groupNames.map { try CredentialName.displayName(from: $0) })
                .union(snapshot.credentials.compactMap(\.groupName).map {
                    try CredentialName.displayName(from: $0)
                }).sorted()
        } catch {
            throw ICloudBackupError.invalidSnapshot
        }
        let encryptedGroups = try encryptedCredentialGroups(groups, key: key)
        var seenNames = Set<Data>()
        var seenIDs = Set<String>()
        let records = try snapshot.credentials.map { credential -> CredentialRecord in
            let displayName = try CredentialName.displayName(from: credential.displayName)
            try CredentialFieldValidation.usageInstructions(credential.usageInstructions)
            if let environmentVariable = credential.environmentVariable {
                try CredentialFieldValidation.environmentVariable(environmentVariable)
            }
            let nameIndex = CredentialIndex.hash(
                normalizedName: CredentialName.normalized(displayName),
                vaultKey: key
            )
            guard seenNames.insert(nameIndex).inserted,
                  !credential.id.isEmpty,
                  seenIDs.insert(credential.id).inserted else {
                throw ICloudBackupError.invalidSnapshot
            }
            let encryptedPayload: Data
            let encryptedFilename: Data?
            let byteSize: Int?
            let contentDigest: Data?
            let kind: CredentialPayloadKind
            switch credential.payload {
            case .text(let value):
                kind = .text
                encryptedPayload = try VaultCrypto.encrypt(value, using: key)
                encryptedFilename = nil
                byteSize = nil
                contentDigest = nil
            case .file(let bytes, let filename):
                guard bytes.count <= FileImport.maxByteCount,
                      !filename.isEmpty,
                      filename.utf8.count <= 255 else {
                    throw ICloudBackupError.invalidSnapshot
                }
                kind = .file
                encryptedPayload = try VaultCrypto.encrypt(bytes, using: key)
                encryptedFilename = try VaultCrypto.encrypt(filename, using: key)
                byteSize = bytes.count
                contentDigest = Data(SHA256.hash(data: bytes))
            case .bundle(let bytes):
                let components: [CredentialComponentInput]
                do {
                    components = try CredentialBundleValidator.validatedComponents(
                        JSONDecoder().decode([CredentialComponentInput].self, from: bytes)
                    )
                } catch {
                    throw ICloudBackupError.invalidSnapshot
                }
                kind = .bundle
                encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(components), using: key)
                encryptedFilename = nil
                byteSize = nil
                contentDigest = nil
            }
            return CredentialRecord(
                id: credential.id,
                nameIndex: nameIndex,
                encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
                encryptedPayload: encryptedPayload,
                encryptedUsageInstructions: try VaultCrypto.encrypt(credential.usageInstructions, using: key),
                encryptedPrivateNotes: try VaultCrypto.encrypt(credential.privateNotes, using: key),
                encryptedGroupName: try credential.groupName.map {
                    try VaultCrypto.encrypt(CredentialName.displayName(from: $0), using: key)
                },
                encryptedEnvironmentVariable: try credential.environmentVariable.map {
                    try VaultCrypto.encrypt($0, using: key)
                },
                payloadKind: kind.rawValue,
                permission: CredentialPermission.ask.rawValue,
                expiresAt: credential.expiresAt.map { sharedDateFormatter.string(from: $0) },
                createdAt: now,
                updatedAt: now,
                encryptedOriginalFilename: encryptedFilename,
                byteSize: byteSize,
                contentDigest: contentDigest,
                deletedAt: credential.deletedAt.map { sharedDateFormatter.string(from: $0) }
            )
        }
        let pendingSettings = try JSONEncoder().encode(snapshot.settings).base64EncodedString()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var databaseReplaced = false
        var restoreCompleted = false
        brokerRequests.pauseAndCancelAll()
        approvalRequests.pauseAndCancelAll()
        cleanupRuntimeFileDeliveries()
        defer {
            let remainPaused = databaseReplaced && !restoreCompleted
            if !wasPaused, !remainPaused {
                brokerRequests.resume()
                approvalRequests.resume()
            }
            agentAccessGate.endExclusiveChange(paused: wasPaused || remainPaused)
        }
        let preciseCurrentSettings = try currentSettings()
        let localSafetySnapshot = try makeEncryptedLocalSafetySnapshot(settings: preciseCurrentSettings)
        try persistLocalSafetySnapshot(localSafetySnapshot)
        try store.replaceICloudBackupContents(
            credentials: records,
            encryptedGroups: encryptedGroups,
            pendingSettings: pendingSettings
        )
        databaseReplaced = true
        try afterDatabaseReplace()
        try applySettings(snapshot.settings)
        try store.setConfigValue(key: VaultStore.iCloudRestorePendingSettingsKey, value: nil)
        restoreCompleted = true
    }

    /// Completes only the local settings journal after the library has loaded.
    /// No cloud access, recovery key, or library replacement is needed.
    public func recoverPendingICloudRestoreSettings(
        applySettings: (ICloudBackupSettings) throws -> Void
    ) throws {
        try recoverPendingICloudRestoreSettings(applySettings: applySettings, beforeJournalClear: {})
    }

    func recoverPendingICloudRestoreSettings(
        applySettings: (ICloudBackupSettings) throws -> Void,
        // Test-only crash seam immediately before the journal clear.
        beforeJournalClear: () throws -> Void
    ) throws {
        guard let encoded = try store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey) else {
            return
        }
        guard let data = Data(base64Encoded: encoded) else {
            throw ICloudBackupError.invalidSnapshot
        }
        let settings: ICloudBackupSettings
        do {
            settings = try JSONDecoder().decode(ICloudBackupSettings.self, from: data)
        } catch {
            throw ICloudBackupError.invalidSnapshot
        }
        let remainPaused: Bool
        switch try store.configValue(key: Self.agentAccessPausedConfigKey) {
        case nil: remainPaused = false
        case "true": remainPaused = true
        default: throw VaultError.databaseError("Agent access pause state is invalid.")
        }
        _ = try agentAccessGate.beginExclusiveChange()
        var recoveryCompleted = false
        brokerRequests.pauseAndCancelAll()
        approvalRequests.pauseAndCancelAll()
        defer {
            let finalPause = recoveryCompleted ? remainPaused : true
            if !finalPause {
                brokerRequests.resume()
                approvalRequests.resume()
            }
            agentAccessGate.endExclusiveChange(paused: finalPause)
        }
        try applySettings(settings)
        try beforeJournalClear()
        try store.setConfigValue(key: VaultStore.iCloudRestorePendingSettingsKey, value: nil)
        recoveryCompleted = true
    }
}

extension VaultStore {
    static let iCloudRestorePendingSettingsKey = "icloud_restore_pending_settings"

    func replaceICloudBackupContents(
        credentials: [CredentialRecord],
        encryptedGroups: String,
        pendingSettings: String
    ) throws {
        try db.write { database in
            try CredentialAccessRecord.deleteAll(database)
            try AgentWriteOperationRecord.deleteAll(database)
            try CredentialRecord.deleteAll(database)
            for credential in credentials { try credentialForPersistence(credential).insert(database) }
            try ConfigRecord(key: Vault.credentialGroupsConfigKey, value: encryptedGroups)
                .save(database)
            try ConfigRecord(key: Self.iCloudRestorePendingSettingsKey, value: pendingSettings)
                .save(database)
        }
    }
}
