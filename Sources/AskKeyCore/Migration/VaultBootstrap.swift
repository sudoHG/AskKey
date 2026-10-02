import CryptoKit
import Foundation
import GRDB

public enum VaultBootstrapState: String, Codable, Equatable, Sendable {
    case fresh
    case current
}

public enum VaultBootstrapError: Error, Equatable, LocalizedError {
    case missingDatabase
    case missingKey
    case invalidState
    case invalidKey
    case unsupportedMigrations
    case schemaMismatch

    public var errorDescription: String? {
        switch self {
        case .missingDatabase:
            return "The vault key exists but its database is missing. Ask Key did not create or overwrite a library."
        case .missingKey:
            return "The library exists but its App-owned key is missing. Existing data was not changed."
        case .invalidState:
            return "The local library state could not be verified. Existing data was not changed."
        case .invalidKey:
            return "The local vault key is invalid. Existing data was not changed."
        case .unsupportedMigrations:
            return "The library has an unsupported migration history. Existing data was not changed."
        case .schemaMismatch:
            return "The library schema does not match the supported baseline. Existing data was not changed."
        }
    }
}

struct VaultBootstrapPaths {
    let directory: URL
    var currentDatabase: URL { directory.appendingPathComponent("credentials-v2.db") }
}

enum VaultBootstrap {
    static func state(paths: VaultBootstrapPaths) throws -> VaultBootstrapState {
        try CurrentLibrarySnapshot.regularFileExists(paths.currentDatabase) ? .current : .fresh
    }

    static func openCurrent(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        switch try state(paths: paths) {
        case .fresh:
            try requireNoKey(keyStore)
            return try createNewLibrary(paths: paths, keyStore: keyStore)
        case .current:
            let data: Data
            do { data = try keyStore.loadAppKey() }
            catch AppKeyStoreError.missingAppKey { throw VaultBootstrapError.missingKey }
            guard data.count == 32 else { throw VaultBootstrapError.invalidKey }
            let key = VaultCrypto.keyFromData(data)
            try validateCurrentLibrary(paths: paths, key: key)
            let store = try VaultStore(path: paths.currentDatabase.path, authenticationKey: key)
            store.bindCredentialAuthenticationKey(key)
            return (store, key)
        }
    }

    private static func requireNoKey(_ keyStore: AppKeyStore) throws {
        do {
            _ = try keyStore.loadAppKey()
            throw VaultBootstrapError.missingDatabase
        } catch AppKeyStoreError.missingAppKey {}
        do {
            _ = try keyStore.loadPendingKey()
            throw VaultBootstrapError.missingDatabase
        } catch AppKeyStoreError.missingPendingKey {}
    }

    private static func createNewLibrary(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        let data = VaultCrypto.keyToData(VaultCrypto.generateKey())
        try keyStore.savePendingKey(data)
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let key = VaultCrypto.keyFromData(data)
        let store = try VaultStore(path: paths.currentDatabase.path)
        do {
            store.bindCredentialAuthenticationKey(key)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: paths.currentDatabase.path)
            try store.db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
            try keyStore.promotePendingKey()
            try keyStore.deletePendingKey()
            return (store, key)
        } catch {
            try? store.close()
            throw error
        }
    }

    private static func validateCurrentLibrary(paths: VaultBootstrapPaths, key: SymmetricKey) throws {
        try CurrentLibrarySnapshot.withCopy(of: paths.currentDatabase) { snapshot in
            // A WAL copy may need fresh SQLite bookkeeping. Only this private
            // copy is writable; reads still validate every credential row.
            let database = try DatabaseQueue(path: snapshot.path)
            defer { try? database.close() }
            try database.read { db in
                _ = try CurrentLibrarySchema.opening(db)
                for record in try CredentialRecord.fetchAll(db) {
                    try CredentialRecordAuthentication.verify(record, using: key)
                }
            }
        }
    }

    static func credentialCount(paths: VaultBootstrapPaths) throws -> Int {
        guard try state(paths: paths) == .current else { return 0 }
        return try CurrentLibrarySnapshot.withCopy(of: paths.currentDatabase) { snapshot in
            let database = try DatabaseQueue(path: snapshot.path)
            defer { try? database.close() }
            return try database.read { db in
                _ = try CurrentLibrarySchema.opening(db)
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials") ?? 0
            }
        }
    }
}
