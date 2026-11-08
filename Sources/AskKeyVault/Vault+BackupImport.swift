import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    /// Opens a backup and computes what importing it would add, skip, rename
    /// and create in the current library, without changing anything (ADR
    /// 0012). Needs a management session or, while the library has no active
    /// or recycled credential, the first-run creation allowance.
    ///
    /// `renameSuffix` gives the text, in the App's language, appended to a
    /// conflicting name: for 1 the plain suffix, for example "(from backup)",
    /// and for 2, 3 and so on a numbered one, for example "(from backup 2)".
    public func planBackupImport(
        _ fileBytes: Data,
        recoveryKey: String,
        renameSuffix: (_ number: Int) -> String
    ) throws -> BackupImportPlan {
        try authorizeBackupImport()
        let snapshot = try BackupFile.open(fileBytes, recoveryKey: try BackupRecoveryKey(parsing: recoveryKey))
        let key = try requireKey()
        let library = try store.agentOrganizationSnapshot(key: key)
        // The first-run allowance covers only the empty library it was checked on.
        if !library.records.isEmpty { try requireManagementSession() }
        let planner = BackupImportPlanner(library: try backupImportLibrary(library, key: key), now: currentDate)
        return BackupImportPlan(backupCreatedAt: snapshot.createdAt,
                                outcome: try planner.plan(snapshot, renameSuffix: renameSuffix),
                                libraryDigest: try BackupImportLibraryState.digest(library, key: key))
    }

    /// Writes a plan in one transaction under the exclusive-change gate after
    /// fresh system authentication, or nothing if the library has changed
    /// since the plan was made. Existing credentials, groups, approvals, timed
    /// allowances and deliveries are left alone; a pending approval whose
    /// frozen state the import changes fails its own commit-time revalidation.
    public func commitBackupImport(
        _ plan: BackupImportPlan,
        using authenticator: ManagementAuthenticator
    ) throws -> BackupImportResult {
        let key = try requireKey()
        let library = try store.agentOrganizationSnapshot(key: key)
        // Both checked before prompting; the library state is checked again
        // inside the write transaction.
        let checkedAt = currentDate
        guard try BackupImportLibraryState.digest(library, key: key) == plan.libraryDigest,
              !plan.credentials.contains(where: { planned in
                  planned.source.deletedAt.map { BackupImportPlanner.retentionEnded(deletedAt: $0, at: checkedAt) } ?? false
              }) else { throw BackupImportError.libraryChanged }
        if !library.records.isEmpty { try requireManagementSession() }
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.manageReason)
        let now = currentDate
        let records = try plan.credentials.map { try importedRecord($0, key: key, now: now) }
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var changed = false
        defer { finishCredentialChange(wasPaused: wasPaused, snapshotChanged: changed) }
        try store.commitBackupImport(records, storedGroups: plan.storedGroups,
                                     libraryDigest: plan.libraryDigest, key: key)
        changed = !records.isEmpty || !plan.storedGroups.isEmpty
        return BackupImportResult(additions: plan.additions, createdGroups: plan.createdGroups)
    }

    private func backupImportLibrary(_ library: AgentOrganizationSnapshot, key: SymmetricKey) throws -> BackupImportLibrary {
        let groups = Set(library.storedGroups).union(try library.assignments(key: key).values)
        return BackupImportLibrary(
            records: library.records, groups: groups.sorted(),
            nameIndex: { CredentialIndex.hash(normalizedName: $0, vaultKey: key) },
            describe: { record in
                .init(name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
                      isRecycled: record.deletedAt != nil,
                      content: .init(components: try self.credentialComponents(from: record, key: key),
                                     usageInstructions: try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key),
                                     privateNotes: try VaultCrypto.decrypt(record.encryptedPrivateNotes, using: key)))
            }
        )
    }

    /// A new record through the same preparation as creation: a new ID, Allow
    /// lowered to Ask every time, the backup's created, expiry and deleted
    /// times, and the import time as the updated time.
    private func importedRecord(_ planned: BackupImportPlannedCredential, key: SymmetricKey,
                                now: Date) throws -> CredentialRecord {
        let source = planned.source
        let permission: CredentialPermission = source.permission == .allowed ? .ask : source.permission
        let id = UUID().uuidString
        var record: CredentialRecord
        switch (source.payloadKind, source.components.first?.value) {
        case (.bundle, _):
            record = try preparedBundleRecord(from: .init(
                name: planned.name, components: source.components, usageInstructions: source.usageInstructions,
                privateNotes: source.privateNotes, groupName: planned.groupName, permission: permission,
                expiresAt: source.expiresAt
            ), id: id, key: key, existing: nil, checkNameAvailability: false)
        case (.text, .text(let value)?) where source.components.count == 1:
            record = try preparedRecord(from: .init(
                name: planned.name, value: value, usageInstructions: source.usageInstructions,
                privateNotes: source.privateNotes, groupName: planned.groupName,
                environmentVariable: source.components[0].delivery.environmentVariable, permission: permission,
                expiresAt: source.expiresAt
            ), id: id, key: key, existing: nil, checkNameAvailability: false)
        case (.file, .file(let filename, let bytes)?) where source.components.count == 1:
            record = try importedFileRecord(planned, file: try FileImport.FrozenFile(originalFilename: filename, bytes: bytes),
                                            permission: permission, id: id, key: key)
        default:
            throw BackupFileError.invalidContents(.invalidCredential)
        }
        record.createdAt = sharedDateFormatter.string(from: source.createdAt)
        record.updatedAt = sharedDateFormatter.string(from: now)
        record.deletedAt = source.deletedAt.map { sharedDateFormatter.string(from: $0) }
        return record
    }

    /// Mirrors the file creation path, whose preparation always checks the
    /// name against the library outside the import transaction.
    private func importedFileRecord(_ planned: BackupImportPlannedCredential, file: FileImport.FrozenFile,
                                    permission: CredentialPermission, id: String, key: SymmetricKey) throws -> CredentialRecord {
        let source = planned.source
        let displayName = try CredentialName.displayName(from: planned.name)
        let group = try CredentialName.optionalDisplayName(planned.groupName)
        try CredentialFieldValidation.usageInstructions(source.usageInstructions)
        let mapping = try optionalEnvironmentVariable(source.components[0].delivery.environmentVariable)
        let now = sharedDateFormatter.string(from: currentDate)
        return CredentialRecord(
            id: id,
            nameIndex: CredentialIndex.hash(normalizedName: CredentialName.normalized(displayName), vaultKey: key),
            encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: key),
            encryptedPayload: try VaultCrypto.encrypt(file.bytes, using: key),
            encryptedUsageInstructions: try VaultCrypto.encrypt(source.usageInstructions, using: key),
            encryptedPrivateNotes: try VaultCrypto.encrypt(source.privateNotes, using: key),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: key) },
            encryptedEnvironmentVariable: try mapping.map { try VaultCrypto.encrypt($0, using: key) },
            payloadKind: CredentialPayloadKind.file.rawValue,
            permission: permission.rawValue,
            expiresAt: source.expiresAt.map { sharedDateFormatter.string(from: $0) },
            createdAt: now,
            updatedAt: now,
            encryptedOriginalFilename: try VaultCrypto.encrypt(file.originalFilename, using: key),
            byteSize: file.byteSize,
            contentDigest: file.contentDigest,
            deletedAt: nil,
            encryptedComponentMetadata: try CredentialComponentMetadata(singleKind: .file, mapping: mapping).encrypted(using: key)
        )
    }
}
