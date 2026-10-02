import CryptoKit
import Darwin
import Foundation
import GRDB

public enum VaultBootstrapState: String, Codable, Equatable, Sendable {
    case fresh
    case legacy
    case mixed
    case migrated
}

public enum VaultBootstrapError: Error, Equatable, LocalizedError {
    case migrationRequired(VaultBootstrapState)
    case missingDatabase
    case invalidState
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .migrationRequired:
            return "This library needs an explicit migration review before it can be used. Existing data and keys have been preserved."
        case .missingDatabase:
            return "The vault key exists but its database is missing. Ask Key did not create or overwrite a library."
        case .invalidState:
            return "The local library state could not be verified. Existing data was not changed."
        case .invalidKey:
            return "The local vault key is invalid. Existing data was not changed."
        }
    }
}

struct VaultBootstrapPaths {
    let directory: URL
    var legacyDatabase: URL { directory.appendingPathComponent("vault.db") }
    var previousDatabase: URL { directory.appendingPathComponent("credentials.db") }
    var currentDatabase: URL { directory.appendingPathComponent("credentials-v2.db") }
    var previousJournal: URL { directory.appendingPathComponent("migration.journal") }
    var currentJournal: URL { directory.appendingPathComponent("migration-v2.journal") }

    var migrationSource: URL {
        FileManager.default.fileExists(atPath: previousDatabase.path) ? previousDatabase : legacyDatabase
    }
}

/// Chooses one format before any writable store is opened. Legacy files are
/// inspected via private snapshots, never auto-upgraded in place by GRDB.
enum VaultBootstrap {
    static func state(paths: VaultBootstrapPaths) throws -> VaultBootstrapState {
        if try regularFileExists(paths.currentDatabase) { return .migrated }
        if try regularFileExists(paths.previousDatabase) { return .mixed }
        if try regularFileExists(paths.legacyDatabase) {
            let hasNewCredentials = try LegacyDatabaseSnapshot.withCopy(of: paths.legacyDatabase, didCopyLegacyFiles: nil) { url in
                let database = try DatabaseQueue(path: url.path)
                return try database.read { db in
                    guard try db.tableExists("credentials") else { return false }
                    return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials") ?? 0) > 0
                }
            }
            return hasNewCredentials ? .mixed : .legacy
        }
        if try regularFileExists(paths.previousJournal) || regularFileExists(paths.currentJournal) {
            throw VaultBootstrapError.invalidState
        }
        return .fresh
    }

    static func openCurrent(
        paths: VaultBootstrapPaths,
        keyStore: MigrationKeyStore
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        let state = try state(paths: paths)
        guard state == .fresh || state == .migrated else {
            throw VaultBootstrapError.migrationRequired(state)
        }
        let data: Data
        let needsPromotion: Bool
        if state == .fresh {
            do {
                _ = try keyStore.loadAppKey()
                throw VaultBootstrapError.missingDatabase
            } catch MigrationKeyStoreError.missingAppKey {
                // Only a pending, never-activated key may resume fresh setup.
            }
            do {
                data = try keyStore.loadPendingKey()
            } catch MigrationKeyStoreError.missingPendingKey {
                let generated = VaultCrypto.keyToData(VaultCrypto.generateKey())
                try keyStore.savePendingKey(generated)
                data = generated
            }
            needsPromotion = true
        } else {
            do {
                data = try keyStore.loadAppKey()
                needsPromotion = false
            } catch MigrationKeyStoreError.missingAppKey {
                data = try keyStore.loadPendingKey()
                needsPromotion = true
            }
        }
        guard data.count == 32 else { throw VaultBootstrapError.invalidKey }
        let key = VaultCrypto.keyFromData(data)
        try FileManager.default.createDirectory(
            at: paths.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directory.path)
        let store = try VaultStore(path: paths.currentDatabase.path)
        store.bindCredentialAuthenticationKey(key)
        do {
            // No unsigned or corrupted current-format row is ever trusted on
            // launch, even if it would otherwise be filtered out of the catalog.
            _ = try store.fetchAllCredentials()
            _ = try store.fetchRecycledCredentials()
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: paths.currentDatabase.path
            )
            if needsPromotion {
                try store.db.writeWithoutTransaction { db in
                    try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                }
                try keyStore.promotePendingKey()
            }
            // A crash after activation may have left this duplicate behind.
            try keyStore.deletePendingKey()
            return (store, key)
        } catch {
            try? store.close()
            throw error
        }
    }

    static func credentialCount(paths: VaultBootstrapPaths) throws -> Int {
        switch try state(paths: paths) {
        case .fresh: return 0
        case .legacy: throw VaultBootstrapError.migrationRequired(.legacy)
        case .mixed: throw VaultBootstrapError.migrationRequired(.mixed)
        case .migrated:
            return try LegacyDatabaseSnapshot.withCopy(of: paths.currentDatabase, didCopyLegacyFiles: nil) { url in
                let database = try DatabaseQueue(path: url.path)
                return try database.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials") ?? 0
                }
            }
        }
    }

    private static func regularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return false }
            throw VaultBootstrapError.invalidState
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw VaultBootstrapError.invalidState
        }
        return true
    }
}
