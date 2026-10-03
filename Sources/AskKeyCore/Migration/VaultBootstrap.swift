import CryptoKit
import Darwin
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
    let durabilityRoot: URL

    init(directory: URL, durabilityRoot: URL? = nil) {
        self.directory = directory
        self.durabilityRoot = durabilityRoot ?? directory.deletingLastPathComponent()
    }

    var currentDatabase: URL { directory.appendingPathComponent("credentials-v2.db") }
    /// Owned by first creation only; never part of the opening decision.
    var creatingDatabase: URL { directory.appendingPathComponent("credentials-v2.db.creating") }
}

enum VaultBootstrapSyncTarget {
    case file(URL)
    case directory(URL)

    var url: URL {
        switch self {
        case .file(let url), .directory(let url): return url
        }
    }
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
    ///
    /// Test seams: `beforeCreationRename` runs after a new library is
    /// complete at `credentials-v2.db.creating` and before it is renamed into
    /// place; `synchronize` performs the actual file or directory sync, so a
    /// caller can wrap the real operation and observe its calls and failures.
    static func openCurrent(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore,
        beforeCreationRename: (URL) throws -> Void = { _ in },
        synchronize: (VaultBootstrapSyncTarget) throws -> Void = VaultBootstrap.synchronize
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        // Reject an invalid boundary before any file or key-store mutation.
        _ = try durableEntryChain(paths: paths)
        let state = try state(paths: paths)
        if let data = try loadKey(keyStore.loadAppKey, missing: .missingAppKey) {
            // An App key is authoritative: no pending-key fallback, and it is
            // never replaced when its database is missing.
            guard state == .current else { throw VaultBootstrapError.missingDatabase }
            let key = try validatedKey(data)
            let authenticated = try validateCurrentLibrary(paths: paths, key: key)
            // With credential rows the App key is authenticated against every
            // row, so any pending key is stale. Without rows the App key cannot
            // be authenticated: it still opens the library, but a pending key
            // that differs from it is left untouched (neither used nor deleted).
            let deletesPendingKey = authenticated > 0 || !hasDifferentPendingKey(keyStore, appKey: data)
            let store = try VaultStore(path: paths.currentDatabase.path, authenticationKey: key)
            do {
                store.bindCredentialAuthenticationKey(key)
                try tightenPermissions(paths: paths)
            } catch {
                try? store.close()
                throw error
            }
            // A crash between promotion and deletion leaves this duplicate.
            if deletesPendingKey { try? keyStore.deletePendingKey() }
            return (store, key)
        }
        let pending = try loadKey(keyStore.loadPendingKey, missing: .missingPendingKey)
        switch state {
        case .fresh:
            // A pending key without any current file is an interrupted first
            // creation before the database existed: resume with that key.
            return try createNewLibrary(paths: paths, keyStore: keyStore, pendingKey: pending.map(validatedKey),
                                        beforeRename: beforeCreationRename, synchronize: synchronize)
        case .current:
            guard let pending else { throw VaultBootstrapError.missingKey }
            return try resumeUnfinishedFirstCreation(paths: paths, keyStore: keyStore, key: validatedKey(pending),
                                                     synchronize: synchronize)
        }
    }

    private static func loadKey(_ load: () throws -> Data, missing: AppKeyStoreError) throws -> Data? {
        do { return try load() }
        catch let error as AppKeyStoreError where error == missing { return nil }
    }

    /// True when a pending key exists and differs from `appKey`, or when it
    /// cannot be read; in both cases it must not be deleted.
    private static func hasDifferentPendingKey(_ keyStore: AppKeyStore, appKey: Data) -> Bool {
        do {
            guard let pending = try loadKey(keyStore.loadPendingKey, missing: .missingPendingKey) else { return false }
            return pending != appKey
        } catch {
            return true
        }
    }

    private static func validatedKey(_ data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VaultBootstrapError.invalidKey }
        return VaultCrypto.keyFromData(data)
    }

    /// Builds the library at `credentials-v2.db.creating` and renames it into
    /// place only when complete, so the current path holds either nothing or a
    /// complete library: `VaultStore` runs every migration on the new file, so
    /// it is at both AskKey identifiers with the legacy tables dropped before
    /// the rename. The pending key is promoted after the rename; a crash in
    /// between is the unfinished first creation of rule 6.
    private static func createNewLibrary(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore, pendingKey: SymmetricKey?,
        beforeRename: (URL) throws -> Void, synchronize: (VaultBootstrapSyncTarget) throws -> Void
    ) throws -> (store: VaultStore, key: SymmetricKey) {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try removeCreationFiles(paths: paths)
        let key: SymmetricKey
        if let pendingKey {
            key = pendingKey
        } else {
            key = VaultCrypto.generateKey()
            try keyStore.savePendingKey(VaultCrypto.keyToData(key))
        }
        do {
            let creating = try VaultStore(path: paths.creatingDatabase.path)
            do {
                try creating.db.writeWithoutTransaction { try $0.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
                try beforeRename(paths.creatingDatabase)
                try creating.close()
            } catch {
                try? creating.close()
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: paths.creatingDatabase.path)
            try synchronize(.file(paths.creatingDatabase))
            // RENAME_EXCL: never replace a current database that appeared.
            // A file system without RENAME_EXCL support (ENOTSUP) fails closed
            // by design; APFS and HFS+ support it.
            guard renamex_np(paths.creatingDatabase.path, paths.currentDatabase.path, UInt32(RENAME_EXCL)) == 0 else {
                throw VaultBootstrapError.invalidState
            }
        } catch {
            try? removeCreationFiles(paths: paths)
            throw error
        }
        let store = try VaultStore(path: paths.currentDatabase.path)
        do {
            store.bindCredentialAuthenticationKey(key)
            try tightenPermissions(paths: paths)
            try makeDurableAndPromote(paths: paths, keyStore: keyStore, synchronize: synchronize)
            return (store, key)
        } catch {
            try? store.close()
            throw error
        }
    }

    /// The single step that turns a pending key into the App key, shared by
    /// first creation and rule 6 recovery. `credentials-v2.db`, the data
    /// directory and the directories holding its entry chain are synchronized
    /// with F_FULLFSYNC first; any failure throws before promotion, leaving
    /// the complete library and the pending key for rule 6 on the next launch.
    /// The App key therefore never exists before its library is durable.
    ///
    /// Every ancestor through the Application Support or isolation root is
    /// synchronized on both creation and recovery. An interrupted attempt may
    /// have created any intermediate level, even when this attempt creates none.
    private static func makeDurableAndPromote(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore,
        synchronize: (VaultBootstrapSyncTarget) throws -> Void
    ) throws {
        for target in try durableEntryChain(paths: paths) {
            try synchronize(target)
        }
        try keyStore.promotePendingKey()
        try keyStore.deletePendingKey()
    }

    /// The database and every directory through the declared root, innermost
    /// first. Keep lexical paths so a symlinked ancestor is opened as a directory.
    private static func durableEntryChain(paths: VaultBootstrapPaths) throws -> [VaultBootstrapSyncTarget] {
        var directory = paths.directory.standardizedFileURL
        let root = paths.durabilityRoot.standardizedFileURL
        guard directory.pathComponents.starts(with: root.pathComponents) else {
            throw VaultBootstrapError.invalidState
        }
        var chain: [VaultBootstrapSyncTarget] = [.file(paths.currentDatabase), .directory(directory)]
        while directory.path != root.path {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { throw VaultBootstrapError.invalidState }
            chain.append(.directory(parent))
            directory = parent
        }
        return chain
    }

    /// Removes only `credentials-v2.db.creating` and its SQLite sidecars.
    /// Like the pre-open identity checks, this relies on the single-opener
    /// assumption: no other process creates a library in this directory.
    private static func removeCreationFiles(paths: VaultBootstrapPaths) throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = paths.creatingDatabase.path + suffix
            guard path.withCString({ Darwin.unlink($0) }) == 0 || errno == ENOENT else {
                throw VaultBootstrapError.invalidState
            }
        }
    }

    static func synchronize(_ target: VaultBootstrapSyncTarget) throws {
        let flags: Int32
        switch target {
        case .file: flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        case .directory: flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
        }
        let descriptor = target.url.path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else { throw VaultBootstrapError.invalidState }
        defer { Darwin.close(descriptor) }
        // F_FULLFSYNC flushes the drive cache; plain fsync is only a fallback
        // for file systems that do not support it.
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        let error = errno
        guard [ENOTSUP, EOPNOTSUPP, EINVAL, ENOTTY].contains(error), fsync(descriptor) == 0 else {
            throw VaultBootstrapError.invalidState
        }
    }

    /// Metadata only; runs after a library has been opened successfully.
    private static func tightenPermissions(paths: VaultBootstrapPaths) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                             ofItemAtPath: paths.currentDatabase.path)
    }

    /// Recovers a crash between database creation and key promotion. The
    /// pending key is promoted only when the database is still exactly what
    /// `createNewLibrary` writes; there are no encrypted rows to authenticate.
    private static func resumeUnfinishedFirstCreation(
        paths: VaultBootstrapPaths, keyStore: AppKeyStore, key: SymmetricKey,
        synchronize: (VaultBootstrapSyncTarget) throws -> Void
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
            try tightenPermissions(paths: paths)
            // The interrupted creation may have crashed before its rename was
            // durable, so recovery repeats the full durability step.
            try makeDurableAndPromote(paths: paths, keyStore: keyStore, synchronize: synchronize)
            return (store, key)
        } catch {
            try? store.close()
            throw error
        }
    }

    /// "Unfinished first creation" (#31 rule 6): contents indistinguishable
    /// from what `createNewLibrary` writes before promotion. Creation ends at
    /// both AskKey identifiers with the legacy tables dropped (its seed always
    /// qualifies); a library created by the baseline-only code before
    /// askkey-0002 existed is at the baseline identifier with its seed.
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

    /// Returns the number of credential rows authenticated with `key`.
    private static func validateCurrentLibrary(paths: VaultBootstrapPaths, key: SymmetricKey) throws -> Int {
        try CurrentLibrarySnapshot.withCopy(of: paths.currentDatabase) { snapshot in
            // A WAL copy may need fresh SQLite bookkeeping. Only this private
            // copy is writable; reads still validate every credential row.
            let database = try DatabaseQueue(path: snapshot.path)
            defer { try? database.close() }
            return try database.read { db in
                _ = try CurrentLibrarySchema.opening(db)
                let records = try CredentialRecord.fetchAll(db)
                for record in records {
                    try CredentialRecordAuthentication.verify(record, using: key)
                }
                return records.count
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
