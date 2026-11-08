import CryptoKit
import Foundation

/// A sealed backup and the only key that opens it. The App shows the key
/// once and writes the bytes; Ask Key keeps neither.
public struct BackupExport: Sendable {
    public let fileBytes: Data
    public let recoveryKey: BackupRecoveryKey
}

public struct BackupSummary: Equatable, Sendable {
    public let createdAt: Date
    /// Credentials outside the Recycle Bin.
    public let credentialCount: Int
    /// Credentials in the Recycle Bin.
    public let recycledCount: Int
    /// Every group, including empty ones.
    public let groupCount: Int
}

extension Vault {
    /// Seals the whole library under a newly generated recovery key. Requires
    /// an active management session and fresh system authentication, the same
    /// boundary as revealing a stored value (ADR 0012). Any record that fails
    /// authentication fails the export; no partial backup is produced.
    public func exportBackup(using authenticator: ManagementAuthenticator) throws -> BackupExport {
        try requireManagementSession()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.revealReason)
        let snapshot = try currentBackupSnapshot(key: requireKey())
        let recoveryKey = BackupRecoveryKey.generate()
        return BackupExport(fileBytes: try BackupFile.seal(snapshot, recoveryKey: recoveryKey),
                            recoveryKey: recoveryKey)
    }

    /// Opens a backup and validates every credential without changing the
    /// library. A recovery-key typo is reported before the file is read.
    public func inspectBackup(_ fileBytes: Data, recoveryKey: String) throws -> BackupSummary {
        try authorizeBackupImport()
        let key = try BackupRecoveryKey(parsing: recoveryKey)
        return try BackupFile.open(fileBytes, recoveryKey: key).summary
    }

    /// Reading a backup needs a management session or, while the library has
    /// no active or recycled credential, the first-run creation allowance.
    func authorizeBackupImport() throws {
        _ = try requireKey()
        if hasActiveManagementSession {
            try requireManagementSession()
        } else {
            try beginOnboardingCreation()
        }
    }

    private func currentBackupSnapshot(key: SymmetricKey) throws -> BackupSnapshot {
        // One authenticated read of every record, recycled ones included, and
        // the stored groups.
        let library = try store.agentOrganizationSnapshot(key: key)
        let credentials = try library.records.map { try backupCredential(from: $0, key: key) }
            .sorted { CredentialName.normalized($0.name) < CredentialName.normalized($1.name) }
        let groups = Set(library.storedGroups).union(credentials.compactMap(\.groupName))
        let snapshot = BackupSnapshot(
            createdAt: try parseExpiry(BackupTimestamp.string(currentDate)),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            groups: groups.sorted(),
            credentials: credentials
        )
        // Refuse to write a backup that inspection would refuse to open.
        do {
            try snapshot.validate()
        } catch let issue as BackupContentsIssue {
            throw BackupFileError.invalidContents(issue)
        }
        return snapshot
    }

    private func backupCredential(from record: CredentialRecord, key: SymmetricKey) throws -> BackupSnapshot.Credential {
        guard let payloadKind = CredentialPayloadKind(rawValue: record.payloadKind),
              let permission = CredentialPermission(rawValue: record.permission) else {
            throw VaultError.databaseError("Credential has an unknown payload kind or permission.")
        }
        return .init(
            name: try VaultCrypto.decrypt(record.encryptedDisplayName, using: key),
            payloadKind: payloadKind,
            components: try credentialComponents(from: record, key: key),
            usageInstructions: try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: key),
            privateNotes: try VaultCrypto.decrypt(record.encryptedPrivateNotes, using: key),
            groupName: try record.encryptedGroupName.map { try VaultCrypto.decrypt($0, using: key) },
            permission: permission,
            expiresAt: try record.expiresAt.map(parseExpiry),
            createdAt: try parseExpiry(record.createdAt),
            updatedAt: try parseExpiry(record.updatedAt),
            deletedAt: try record.deletedAt.map(parseExpiry)
        )
    }
}
