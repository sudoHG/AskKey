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
        if try CurrentLibrarySnapshot.regularFileExists(paths.currentDatabase) { return .current }
        for suffix in ["-wal", "-shm", "-journal"] {
            guard try !CurrentLibrarySnapshot.regularFileExists(
                URL(fileURLWithPath: paths.currentDatabase.path + suffix)
            ) else { throw VaultBootstrapError.invalidState }
        }
        return .fresh
    }

    /// Implements the opening decision table of #31. Every rejected state
    /// leaves every file and key-store value unchanged.
    static func openCurrent(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        let state = try state(paths: paths)
        if let data = try loadKey(keyStore.loadAppKey, missing: .missingAppKey) {
            // An App key is authoritative: no pending-key fallback, and it is
            // never replaced when its database is missing.
            guard state == .current else { throw VaultBootstrapError.missingDatabase }
            let key = try validatedKey(data)
            try validateCurrentLibrary(paths: paths, key: key)
            let store = try VaultStore(path: paths.currentDatabase.path, authenticationKey: key)
            store.bindCredentialAuthenticationKey(key)
            return (store, key)
        }
        let pending = try loadKey(keyStore.loadPendingKey, missing: .missingPendingKey)
        switch state {
        case .fresh:
            // A pending key without any current file is an interrupted first
            // creation before the database existed: resume with that key.
            return try createNewLibrary(paths: paths, keyStore: keyStore, pendingKey: pending.map(validatedKey))
        case .current:
            guard let pending else { throw VaultBootstrapError.missingKey }
            return try resumeUnfinishedFirstCreation(paths: paths, keyStore: keyStore, key: validatedKey(pending))
        }
    }

    private static func loadKey(_ load: () throws -> Data, missing: AppKeyStoreError) throws -> Data? {
        do { return try load() }
        catch let error as AppKeyStoreError where error == missing { return nil }
    }

    private static func validatedKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VaultBootstrapError.invalidKey }
        return VaultCrypto.keyFromData(data)
    }

    private static func createNewLibrary(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore, pendingKey: SymmetricKey?
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        let key: SymmetricKey
        if let pendingKey {
            key = pendingKey
        } else {
            key = VaultCrypto.generateKey()
            try keyStore.savePendingKey(VaultCrypto.keyToData(key))
        }
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
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

    /// Recovers a crash between database creation and key promotion. The
    /// pending key is promoted only when the database is still exactly what
    /// `createNewLibrary` writes; there are no encrypted rows to authenticate.
    private static func resumeUnfinishedFirstCreation(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore, key: SymmetricKey
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        try CurrentLibrarySnapshot.withCopy(of: paths.currentDatabase) { snapshot in
            let database = try DatabaseQueue(path: snapshot.path)
            defer { try? database.close() }
            try database.read(requireUnfinishedFirstCreation)
        }
        let store = try VaultStore(path: paths.currentDatabase.path, authenticationKey: key,
                                   validation: requireUnfinishedFirstCreation)
        do {
            store.bindCredentialAuthenticationKey(key)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: paths.currentDatabase.path)
            try keyStore.promotePendingKey()
            try keyStore.deletePendingKey()
            return (store, key)
        } catch {
            try? store.close()
            throw error
        }
    }

    /// "Unfinished first creation" (#31 rule 6): contents indistinguishable
    /// from what `createNewLibrary` writes before promotion. Creation ends at
    /// both AskKey identifiers with the legacy tables dropped (its seed always
    /// qualifies); a crash between the two migrations, or a creation by the
    /// baseline-only code, leaves only the baseline identifier with its seed.
    /// The expected value comes from the real migrator at the same
    /// identifiers. Any extra row or other schema disqualifies it.
    static func requireUnfinishedFirstCreation(_ db: Database) throws {
        let target: String
        switch try CurrentLibrarySchema.opening(db) {
        case .baseline: target = CurrentLibrarySchema.baselineIdentifier
        case .current: target = CurrentLibrarySchema.dropLegacyTablesIdentifier
        case .legacyV15: throw VaultBootstrapError.missingKey
        }
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try CurrentLibrarySchema.migrator().migrate(expected, upTo: target)
        guard try CurrentLibrarySchema.normalizedSchema(db) == expected.read(CurrentLibrarySchema.normalizedSchema),
              try FirstCreationContents(db) == expected.read(FirstCreationContents.init) else {
            throw VaultBootstrapError.missingKey
        }
    }

    /// Creation-written contents with generated identifiers and timestamps
    /// abstracted away, so the expected value comes from the migrator.
    private struct FirstCreationContents: Equatable {
        let rowCounts: [String: Int]
        let project: [String: DatabaseValue]
        let environment: [String: DatabaseValue]
        let config: [String: DatabaseValue]

        init(_ db: Database) throws {
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT GLOB 'sqlite_*' AND name != 'grdb_migrations'
                ORDER BY name
                """)
            var counts: [String: Int] = [:]
            for table in tables {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier)")
            }
            rowCounts = counts
            // References to the seed project compare equal; any other value
            // must match the migrator's literally.
            var projectID = DatabaseValue.null
            if counts["projects"] != nil || counts["environments"] != nil {
                let projects = try Row.fetchAll(db, sql: "SELECT * FROM projects")
                let environments = try Row.fetchAll(db, sql: "SELECT * FROM environments")
                guard projects.count == 1, environments.count == 1 else {
                    project = [:]; environment = [:]; config = [:]
                    return
                }
                projectID = projects[0]["id"]
                project = Self.columns(projects[0], excluding: ["id", "created_at", "updated_at"], seed: projectID)
                environment = Self.columns(environments[0], excluding: ["id", "created_at"], seed: projectID)
            } else {
                // With the legacy tables dropped, the seed project's generated
                // identifier survives only as the canonical UUID text that
                // creation stored in `active_project_id`.
                let active = try DatabaseValue.fetchOne(
                    db, sql: "SELECT value FROM config WHERE key = 'active_project_id'") ?? .null
                if case .string(let text) = active.storage, UUID(uuidString: text)?.uuidString == text {
                    projectID = active
                }
                project = [:]; environment = [:]
            }
            var values: [String: DatabaseValue] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM config") {
                values[row["key"]] = Self.abstracted(row["value"], seed: projectID)
            }
            config = values
        }

        private static func abstracted(_ value: DatabaseValue, seed projectID: DatabaseValue) -> DatabaseValue {
            value == projectID && !value.isNull ? "\u{0}seed-project".databaseValue : value
        }

        private static func columns(
            _ row: Row, excluding volatile: Set<String>, seed projectID: DatabaseValue
        ) -> [String: DatabaseValue] {
            var result: [String: DatabaseValue] = [:]
            for (column, value) in row where !volatile.contains(column) {
                result[column] = abstracted(value, seed: projectID)
            }
            return result
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
