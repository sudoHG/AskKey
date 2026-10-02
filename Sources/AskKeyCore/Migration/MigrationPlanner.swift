import CryptoKit
import Darwin
import Foundation
import GRDB

public enum MigrationPreviewError: Error, Equatable, LocalizedError {
    case cancelled
    case invalidLegacyDatabase(String)
    case invalidLegacyName(String)
    case snapshotCleanupFailed(String)
    case unsupportedLegacyPermission(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Migration preview was cancelled. The existing vault was not changed."
        case .invalidLegacyDatabase(let message):
            return "The existing vault could not be read safely: \(message)"
        case .invalidLegacyName(let name):
            return "The existing credential name is not valid for migration: \(name)"
        case .snapshotCleanupFailed(let message):
            return "The temporary migration snapshot could not be removed: \(message)"
        case .unsupportedLegacyPermission(let permission):
            return "The existing credential has an unknown permission: \(permission)"
        }
    }
}

public final class MigrationPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    fileprivate var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Produces a side-by-side vNext preview from the last supported legacy vault.
/// The database is opened read-only and the result exists only in memory.
public struct MigrationPlanner: Sendable {
    private static let supportedMigrations = ["v1", "v3", "v4", "v5", "v6", "v7"]

    private let databaseURL: URL
    private let legacyKey: SymmetricKey
    private let migrationKey: SymmetricKey

    public init(databaseURL: URL, legacyKey: SymmetricKey, migrationKey: SymmetricKey) {
        self.databaseURL = databaseURL
        self.legacyKey = legacyKey
        self.migrationKey = migrationKey
    }

    public func preview(cancellation: MigrationPreviewCancellation? = nil) throws -> MigrationPreview {
        try preview(cancellation: cancellation, failAfterCredentialCount: nil)
    }

    func preview(
        cancellation: MigrationPreviewCancellation? = nil,
        failAfterCredentialCount: Int? = nil,
        didPrepareCredential: ((Int) -> Void)? = nil,
        didCopyLegacyFiles: (() throws -> Void)? = nil
    ) throws -> MigrationPreview {
        if cancellation?.isCancelled == true { throw MigrationPreviewError.cancelled }

        let fingerprint = try MigrationSourceFingerprint.digest(of: databaseURL)
        let snapshot: MigrationSnapshotRows
        do {
            snapshot = try LegacyDatabaseSnapshot.withCopy(
                of: databaseURL,
                didCopyLegacyFiles: didCopyLegacyFiles
            ) { snapshotURL in
                var configuration = Configuration()
                // The isolated copy may need to create SQLite WAL bookkeeping
                // in its temporary directory. query_only forbids SQL writes
                // while the original files remain completely unopened.
                configuration.prepareDatabase { db in
                    try db.execute(sql: "PRAGMA query_only = ON")
                }
                let database = try DatabaseQueue(path: snapshotURL.path, configuration: configuration)
                return try database.read { db in
                    try Self.validateLegacyDatabase(db)
                    let request = SQLRequest<LegacyRow>(sql: """
                    SELECT s.id AS secret_id,
                           s.name AS secret_name,
                           s.description AS secret_description,
                           s.agent_access AS agent_access,
                           p.name AS project_name,
                           e.name AS environment_name,
                           sv.encrypted_value AS encrypted_value
                    FROM secret_values sv
                    JOIN secrets s ON s.id = sv.secret_id
                    JOIN projects p ON p.id = s.project_id
                    JOIN environments e
                      ON e.id = sv.environment_id
                     AND e.project_id = s.project_id
                    ORDER BY p.name, COALESCE(e.name, ''), s.name, sv.id
                    """)
                    let rows = try request.fetchAll(db)
                    let valueCount = try Self.requiredCount(
                        db,
                        sql: "SELECT COUNT(*) FROM secret_values"
                    )
                    let secretCount = try Self.requiredCount(
                        db,
                        sql: "SELECT COUNT(*) FROM secrets"
                    )
                    let secretsWithValues = try Self.requiredCount(
                        db,
                        sql: "SELECT COUNT(DISTINCT secret_id) FROM secret_values"
                    )
                    guard rows.count == valueCount, secretCount == secretsWithValues else {
                        throw MigrationPreviewError.invalidLegacyDatabase(
                            "Legacy records are incomplete or cannot be associated safely."
                        )
                    }
                    let credentials = try db.tableExists("credentials") ? CredentialRecord.fetchAll(db) : []
                    let groups = try ConfigRecord.fetchOne(db, key: "credential_groups")?.value
                    let access = try db.tableExists("credential_access_records") ? CredentialAccessRecord.fetchAll(db) : []
                    return MigrationSnapshotRows(legacy: rows, credentials: credentials, encryptedGroups: groups, accessRecords: access)
                }
            }
        } catch let error as MigrationPreviewError {
            throw error
        } catch {
            throw MigrationPreviewError.invalidLegacyDatabase(error.localizedDescription)
        }
        guard try MigrationSourceFingerprint.digest(of: databaseURL) == fingerprint else {
            throw MigrationCommitError.legacyVaultChanged
        }

        var proposals: [MigrationProposal] = []
        proposals.reserveCapacity(snapshot.legacy.count + snapshot.credentials.count)

        for row in snapshot.legacy {
            if cancellation?.isCancelled == true { throw MigrationPreviewError.cancelled }
            if let limit = failAfterCredentialCount, proposals.count == limit {
                throw MigrationPreviewInjectedFailure()
            }

            let displayName: String
            do {
                displayName = try CredentialName.displayName(from: row.secretName)
            } catch {
                throw MigrationPreviewError.invalidLegacyName(row.secretName)
            }
            let normalizedName = CredentialName.normalized(displayName)
            let originalPermission = try Self.permission(from: row.agentAccess)
            let permission = CredentialPermission.ask
            let value: String
            do {
                value = try VaultCrypto.decrypt(row.encryptedValue, using: legacyKey)
            } catch {
                throw MigrationPreviewError.invalidLegacyDatabase(
                    "Credential '\(displayName)' could not be decrypted."
                )
            }
            let usageInstructions = row.secretDescription ?? ""
            do {
                try CredentialFieldValidation.usageInstructions(usageInstructions)
            } catch {
                throw MigrationPreviewError.invalidLegacyDatabase(
                    "Credential metadata exceeds the Broker field limit."
                )
            }
            let groupName = row.projectName == "Default" ? nil : row.projectName
            let index = CredentialIndex.hash(normalizedName: normalizedName, vaultKey: migrationKey)
            var staged = StagedCredential(
                id: UUID().uuidString,
                nameIndex: index,
                encryptedDisplayName: try VaultCrypto.encrypt(displayName, using: migrationKey),
                encryptedPayload: try VaultCrypto.encrypt(value, using: migrationKey),
                encryptedUsageInstructions: try VaultCrypto.encrypt(usageInstructions, using: migrationKey),
                encryptedPrivateNotes: try VaultCrypto.encrypt("", using: migrationKey),
                encryptedGroupName: try groupName.map { try VaultCrypto.encrypt($0, using: migrationKey) },
                payloadKind: .text,
                permission: permission
            )
            // The old name was also its delivery mapping. Preserve this rather
            // than producing a text credential the Broker cannot deliver.
            if (try? Vault.validateSecretName(displayName)) != nil {
                staged.encryptedEnvironmentVariable = try VaultCrypto.encrypt(displayName, using: migrationKey)
            }
            proposals.append(.init(
                displayName: displayName,
                normalizedName: normalizedName,
                permission: permission,
                suggestedGroupName: groupName,
                source: .init(
                    projectName: row.projectName,
                    environmentName: row.environmentName ?? "Default",
                    secretID: row.secretID
                ),
                stagedCredential: staged,
                originalPermission: originalPermission
            ))
            didPrepareCredential?(proposals.count)
        }

        for record in snapshot.credentials {
            if cancellation?.isCancelled == true { throw MigrationPreviewError.cancelled }
            if let limit = failAfterCredentialCount, proposals.count == limit { throw MigrationPreviewInjectedFailure() }
            proposals.append(try migrateExistingCredential(record))
            didPrepareCredential?(proposals.count)
        }

        var groups = Set(proposals.compactMap(\.suggestedGroupName))
        if let encoded = snapshot.encryptedGroups {
            guard let encrypted = Data(base64Encoded: encoded) else {
                throw MigrationPreviewError.invalidLegacyDatabase("Credential groups are invalid.")
            }
            let names = try JSONDecoder().decode([String].self, from: VaultCrypto.decryptData(encrypted, using: legacyKey))
            for name in names { groups.insert(try CredentialName.displayName(from: name)) }
        }
        let accessRecords = try snapshot.accessRecords.map { record -> StagedCredentialAccessRecord in
            let cleartext = try VaultCrypto.decryptData(record.encryptedRecord, using: legacyKey)
            _ = try JSONDecoder().decode(CredentialAccessEvent.self, from: cleartext)
            return .init(id: record.id, encryptedRecord: try VaultCrypto.encrypt(cleartext, using: migrationKey))
        }

        let conflicts = Dictionary(grouping: proposals, by: \.normalizedName)
            .filter { $0.value.count > 1 }
            .map { normalizedName, matches in
                MigrationNameConflict(
                    normalizedName: normalizedName,
                    displayNames: matches.map(\.displayName),
                    sources: matches.map(\.source)
                )
            }
            .sorted { lhs, rhs in lhs.normalizedName < rhs.normalizedName }

        return MigrationPreview(
            proposals: proposals, conflicts: conflicts, sourceFingerprint: fingerprint,
            groupNames: groups.sorted(), accessRecords: accessRecords
        )
    }

    private func migrateExistingCredential(_ record: CredentialRecord) throws -> MigrationProposal {
        if record.authenticationTag != nil {
            try CredentialRecordAuthentication.verify(record, using: legacyKey)
        }
        guard let originalPermission = CredentialPermission(rawValue: record.permission),
              let kind = CredentialPayloadKind(rawValue: record.payloadKind), !record.id.isEmpty else {
            throw MigrationPreviewError.invalidLegacyDatabase("Credential metadata is invalid.")
        }
        let name = try CredentialName.displayName(from: VaultCrypto.decrypt(record.encryptedDisplayName, using: legacyKey))
        let group = try record.encryptedGroupName.map {
            try CredentialName.displayName(from: VaultCrypto.decrypt($0, using: legacyKey))
        }
        let usageInstructions = try VaultCrypto.decrypt(record.encryptedUsageInstructions, using: legacyKey)
        do {
            try CredentialFieldValidation.usageInstructions(usageInstructions)
        } catch {
            throw MigrationPreviewError.invalidLegacyDatabase(
                "Credential metadata exceeds the Broker field limit."
            )
        }
        let environmentVariable = try record.encryptedEnvironmentVariable.map {
            try VaultCrypto.decrypt($0, using: legacyKey)
        }
        if let environmentVariable {
            do {
                try CredentialFieldValidation.environmentVariable(environmentVariable)
            } catch {
                throw MigrationPreviewError.invalidLegacyDatabase(
                    "Credential environment mapping is invalid."
                )
            }
        }
        let clearPayload = try VaultCrypto.decryptData(record.encryptedPayload, using: legacyKey)
        switch kind {
        case .text:
            guard String(data: clearPayload, encoding: .utf8) != nil else {
                throw MigrationPreviewError.invalidLegacyDatabase("Text credential is invalid.")
            }
        case .file:
            guard let filename = record.encryptedOriginalFilename,
                  let digest = record.contentDigest,
                  record.byteSize == clearPayload.count,
                  digest == Data(SHA256.hash(data: clearPayload)) else {
                throw MigrationPreviewError.invalidLegacyDatabase("File credential is incomplete.")
            }
            _ = try FileImport.FrozenFile(
                originalFilename: VaultCrypto.decrypt(filename, using: legacyKey), bytes: clearPayload
            )
        case .bundle:
            _ = try CredentialBundleValidator.validatedComponents(
                JSONDecoder().decode([CredentialComponentInput].self, from: clearPayload)
            )
        }
        for timestamp in [record.expiresAt, record.deletedAt, record.createdAt, record.updatedAt].compactMap({ $0 }) {
            guard ISO8601DateFormatter().date(from: timestamp) != nil else {
                throw MigrationPreviewError.invalidLegacyDatabase("Credential timestamp is invalid.")
            }
        }
        func reencryptText(_ data: Data) throws -> Data {
            try VaultCrypto.encrypt(VaultCrypto.decrypt(data, using: legacyKey), using: migrationKey)
        }
        let staged = StagedCredential(
            id: record.id,
            nameIndex: CredentialIndex.hash(normalizedName: CredentialName.normalized(name), vaultKey: migrationKey),
            encryptedDisplayName: try VaultCrypto.encrypt(name, using: migrationKey),
            encryptedPayload: try VaultCrypto.encrypt(clearPayload, using: migrationKey),
            encryptedUsageInstructions: try VaultCrypto.encrypt(usageInstructions, using: migrationKey),
            encryptedPrivateNotes: try reencryptText(record.encryptedPrivateNotes),
            encryptedGroupName: try group.map { try VaultCrypto.encrypt($0, using: migrationKey) },
            payloadKind: kind, permission: .ask,
            encryptedEnvironmentVariable: try environmentVariable.map {
                try VaultCrypto.encrypt($0, using: migrationKey)
            },
            encryptedOriginalFilename: try record.encryptedOriginalFilename.map(reencryptText),
            byteSize: record.byteSize, contentDigest: record.contentDigest,
            expiresAt: record.expiresAt, createdAt: record.createdAt, updatedAt: record.updatedAt,
            deletedAt: record.deletedAt
        )
        return MigrationProposal(
            displayName: name, normalizedName: CredentialName.normalized(name), permission: .ask,
            suggestedGroupName: group,
            source: .init(projectName: group ?? "", environmentName: "", secretID: record.id),
            stagedCredential: staged, originalPermission: originalPermission
        )
    }

    private static func permission(from legacyPermission: String) throws -> CredentialPermission {
        guard let policy = AgentAccessPolicy(rawValue: legacyPermission) else {
            throw MigrationPreviewError.unsupportedLegacyPermission(legacyPermission)
        }
        switch policy {
        case .allowed: return .allowed
        case .requiresApproval, .strict: return .ask
        case .blocked: return .hidden
        }
    }

    private static func validateLegacyDatabase(_ db: Database) throws {
        let migrations = try String.fetchAll(
            db,
            sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
        )
        guard migrations.starts(with: supportedMigrations) else {
            throw MigrationPreviewError.invalidLegacyDatabase(
                "Unsupported legacy schema version."
            )
        }
        let integrity = try String.fetchAll(db, sql: "PRAGMA integrity_check")
        guard integrity == ["ok"] else {
            throw MigrationPreviewError.invalidLegacyDatabase(
                "SQLite integrity check failed: \(integrity.joined(separator: "; "))"
            )
        }
        let foreignKeyFailures = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        guard foreignKeyFailures.isEmpty else {
            throw MigrationPreviewError.invalidLegacyDatabase(
                "Legacy vault contains invalid relationships."
            )
        }
    }

    private static func requiredCount(_ db: Database, sql: String) throws -> Int {
        guard let count = try Int.fetchOne(db, sql: sql) else {
            throw MigrationPreviewError.invalidLegacyDatabase("A required row count is missing.")
        }
        return count
    }
}

struct MigrationPreviewInjectedFailure: Error, Equatable {}

private struct MigrationSnapshotRows {
    let legacy: [LegacyRow]
    let credentials: [CredentialRecord]
    let encryptedGroups: String?
    let accessRecords: [CredentialAccessRecord]
}

private struct LegacyRow: Decodable, FetchableRecord {
    let secretID: String
    let secretName: String
    let secretDescription: String?
    let agentAccess: String
    let projectName: String
    let environmentName: String?
    let encryptedValue: Data

    enum CodingKeys: String, CodingKey {
        case secretID = "secret_id"
        case secretName = "secret_name"
        case secretDescription = "secret_description"
        case agentAccess = "agent_access"
        case projectName = "project_name"
        case environmentName = "environment_name"
        case encryptedValue = "encrypted_value"
    }
}

/// SQLite may update a WAL shared-memory file even on a read-only connection.
/// Fingerprint an isolated file copy, then use SQLite's online backup API to
/// create a consistent snapshot without opening any original file in SQLite.
final class LegacyDatabaseSnapshot {
    let directory: URL
    let databaseURL: URL

    private init(source: URL, didCopyLegacyFiles: (() throws -> Void)?) throws {
        try Self.removeAbandonedCopies()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AskKeyMigrationPreview-\(getpid())-\(UUID().uuidString)",
                isDirectory: true
        )
        databaseURL = directory.appendingPathComponent("vault.db")
        let copiedDatabaseURL = directory.appendingPathComponent("legacy.db")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let fingerprintBefore = try Self.fingerprint(databaseURL: source)
            for suffix in ["", "-wal", "-shm"] {
                let sourceFile = URL(fileURLWithPath: source.path + suffix)
                guard FileManager.default.fileExists(atPath: sourceFile.path) else { continue }
                let copiedFile = URL(fileURLWithPath: copiedDatabaseURL.path + suffix)
                try FileManager.default.copyItem(at: sourceFile, to: copiedFile)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: copiedFile.path
                )
            }
            try didCopyLegacyFiles?()
            guard try Self.fingerprint(databaseURL: source) == fingerprintBefore else {
                throw MigrationPreviewError.invalidLegacyDatabase(
                    "The legacy vault changed while its preview snapshot was being created."
                )
            }

            let copiedDatabase = try DatabaseQueue(path: copiedDatabaseURL.path)
            let consistentDatabase = try DatabaseQueue(path: databaseURL.path)
            try copiedDatabase.backup(to: consistentDatabase)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            for suffix in ["", "-wal", "-shm"] {
                let copiedFile = URL(fileURLWithPath: copiedDatabaseURL.path + suffix)
                guard FileManager.default.fileExists(atPath: copiedFile.path) else { continue }
                try FileManager.default.removeItem(at: copiedFile)
            }
        } catch {
            do {
                try remove()
            } catch let cleanupError {
                throw MigrationPreviewError.snapshotCleanupFailed(
                    "\(cleanupError.localizedDescription); original error: \(error.localizedDescription)"
                )
            }
            throw error
        }
    }

    static func withCopy<T>(
        of source: URL,
        didCopyLegacyFiles: (() throws -> Void)?,
        _ body: (URL) throws -> T
    ) throws -> T {
        let snapshot = try LegacyDatabaseSnapshot(
            source: source,
            didCopyLegacyFiles: didCopyLegacyFiles
        )
        let result: T
        do {
            result = try body(snapshot.databaseURL)
        } catch let originalError {
            do {
                try snapshot.remove()
            } catch let cleanupError {
                throw MigrationPreviewError.snapshotCleanupFailed(
                    "\(cleanupError.localizedDescription); original error: \(originalError.localizedDescription)"
                )
            }
            throw originalError
        }
        do {
            try snapshot.remove()
        } catch {
            throw MigrationPreviewError.snapshotCleanupFailed(error.localizedDescription)
        }
        return result
    }

    private func remove() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private static func removeAbandonedCopies() throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
        let names = try fileManager.contentsOfDirectory(atPath: temporaryDirectory.path)
        for name in names where name.hasPrefix("AskKeyMigrationPreview-") {
            let components = name.split(separator: "-", maxSplits: 2)
            guard components.count == 3, let processID = Int32(components[1]) else { continue }
            if kill(processID, 0) == 0 || errno == EPERM { continue }
            guard errno == ESRCH else { continue }
            do {
                try fileManager.removeItem(at: temporaryDirectory.appendingPathComponent(name))
            } catch {
                throw MigrationPreviewError.snapshotCleanupFailed(error.localizedDescription)
            }
        }
    }

    private static func fingerprint(databaseURL: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm"] {
            let fileURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let bytes = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            result[suffix] = Data(SHA256.hash(data: bytes))
        }
        guard result[""] != nil else {
            throw MigrationPreviewError.invalidLegacyDatabase("Legacy vault file is missing.")
        }
        return result
    }
}
