import Foundation
import GRDB
import XCTest
@testable import AskKeyCore

/// askkey-0002-drop-legacy-tables (#33): opening states after the drop
/// migration, kept legacy data, and unfinished first creations before and
/// after it existed. Uses the v15 fixture helpers of `CurrentLibraryAdoptionTests`.
extension CurrentLibraryAdoptionTests {
    func testAdoptionKeepsLegacyTablesHoldingASecretAndReopens() throws {
        try assertLegacyTablesKept(sql: """
            INSERT INTO secrets (id, project_id, name, created_at, updated_at)
            SELECT 'SYNTHETIC-secret', id, 'SYNTHETIC-SECRET', 'now', 'now' FROM projects
            """)
    }

    func testAdoptionKeepsLegacyTablesHoldingAnActivityRowAndReopens() throws {
        try assertLegacyTablesKept(sql: """
            INSERT INTO activity_log (id, secret_name, project_name, environment_name, source, accessed_at)
            VALUES ('SYNTHETIC', 'S', 'P', 'E', 'cli', 'now')
            """)
    }

    func testAdoptionKeepsLegacyTablesWithACustomizedDefaultProject() throws {
        try assertLegacyTablesKept(sql: "UPDATE projects SET icon = 'SYNTHETIC-icon'")
    }

    /// Guards `foreignKeyChecks: .immediate` on askkey-0002: a deferred,
    /// database-wide foreign_key_check would reject this kept legacy row and
    /// make the library impossible to open.
    func testAdoptionKeepsLegacyRowsViolatingAForeignKeyAndReopens() throws {
        try assertLegacyTablesKept(sql: """
            INSERT INTO secrets (id, project_id, name, created_at, updated_at)
            VALUES ('SYNTHETIC-orphan', 'SYNTHETIC-missing-project', 'SYNTHETIC-ORPHAN', 'now', 'now')
            """, foreignKeysEnabled: false)
    }

    func testCreationRunsDropMigrationBeforeRename() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        var observedCreation = false
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeCreationRename: { creating in
            observedCreation = true
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.currentDatabase.path))
            try CurrentLibrarySnapshot.withCopy(of: creating) { snapshot in
                let database = try DatabaseQueue(path: snapshot.path)
                defer { try? database.close() }
                try database.read { db in
                    XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                                   Self.currentIdentifiers)
                    XCTAssertEqual(try CurrentLibrarySchema.legacyTables.filter { try db.tableExists($0) }, [])
                    XCTAssertEqual(try CurrentLibrarySchema.opening(db), .current)
                    XCTAssertNoThrow(try VaultBootstrap.requireUnfinishedFirstCreation(db))
                }
            }
        })
        XCTAssertTrue(observedCreation)
        XCTAssertEqual(try identifiers(opened.store), Self.currentIdentifiers)
        XCTAssertEqual(try existingLegacyTables(opened.store), [])
        try opened.store.close()
        XCTAssertEqual(keys.appKey?.count, 32)
        XCTAssertNil(keys.pendingKey)
    }

    func testMigratedLibraryWithUnknownExtraIdentifierFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: Self.currentHistorySQL + Self.dropLegacyTablesSQL
                               + "INSERT INTO grdb_migrations VALUES ('unknown');", error: .unsupportedMigrations)
    }

    func testDropIdentifierWithoutBaselineFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: """
            DELETE FROM grdb_migrations;
            INSERT INTO grdb_migrations VALUES ('askkey-0002-drop-legacy-tables');
            """ + Self.dropLegacyTablesSQL, error: .unsupportedMigrations)
    }

    func testBaselineWithDroppedLegacyTablesFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: """
            DELETE FROM grdb_migrations;
            INSERT INTO grdb_migrations VALUES ('askkey-0001-baseline');
            """ + Self.dropLegacyTablesSQL, error: .schemaMismatch)
    }

    func testMigratedLibraryWithExtraColumnFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: Self.currentHistorySQL + Self.dropLegacyTablesSQL
                               + "ALTER TABLE credentials ADD COLUMN unknown TEXT;", error: .schemaMismatch)
    }

    func testMigratedLibraryWithPartiallyDroppedLegacyTablesFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: Self.currentHistorySQL + "DROP TABLE activity_log;", error: .schemaMismatch)
    }

    func testPendingKeyIsPromotedForBaselineOnlyUnfinishedCreation() throws {
        let (paths, keys) = try unfinishedBaselineCreation()
        let pending = try XCTUnwrap(keys.pendingKey)
        try addHistoricalSiblings(paths)
        let siblings = try directoryBytes(paths.directory).filter { $0.key != "credentials-v2.db" }
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), pending)
        XCTAssertEqual(try identifiers(opened.store), Self.currentIdentifiers)
        XCTAssertEqual(try existingLegacyTables(opened.store), [])
        XCTAssertEqual(try opened.store.db.read { try CurrentLibrarySchema.normalizedSchema($0) },
                       try v15SchemaWithoutLegacyTables())
        try opened.store.close()
        XCTAssertEqual(try directoryBytes(paths.directory).filter { $0.key != "credentials-v2.db" }, siblings)
        XCTAssertEqual(keys.appKey, pending)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(keys.mutations, 2)

        let reopened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try reopened.store.close()
        XCTAssertEqual(keys.mutations, 3, "the App-key reopen only calls deletePendingKey")
    }

    /// A library left at `[askkey-0001-baseline]` by the baseline-only code,
    /// already holding an App key and authenticated credential rows, runs
    /// askkey-0002 on open: the empty legacy tables are dropped and every
    /// credential stays readable with the same App key.
    func testBaselineLibraryWithAppKeyAndCredentialsRunsDropMigrationAndKeepsCredentials() throws {
        let (paths, keys) = try unfinishedBaselineCreation()
        let appKey = try XCTUnwrap(keys.pendingKey)
        let source = try temporaryDirectory().appendingPathComponent("SYNTHETIC-source.db")
        let sourceStore = try VaultStore(path: source.path)
        let key = VaultCrypto.keyFromData(appKey)
        sourceStore.bindCredentialAuthenticationKey(key)
        let expected = ["SYNTHETIC-TOKEN-A": "synthetic-a", "SYNTHETIC-TOKEN-B": "synthetic-b"]
        let sourceVault = Vault(store: sourceStore, key: key)
        try sourceVault.beginManagementSession(using: .allow)
        for (name, value) in expected.sorted(by: { $0.key < $1.key }) {
            _ = try sourceVault.createTextCredential(
                .init(name: name, value: value, permission: .allowed), using: .allow)
        }
        sourceVault.lock()
        try sourceStore.close()
        let baseline = try DatabaseQueue(path: paths.currentDatabase.path)
        try baseline.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS source", arguments: [source.path])
            try db.execute(sql: "INSERT INTO credentials SELECT * FROM source.credentials")
            try db.execute(sql: "DETACH DATABASE source")
        }
        try baseline.close()
        keys.appKey = appKey
        keys.pendingKey = nil
        let credentialRows = try allDataRows(paths.currentDatabase)["credentials"]
        XCTAssertEqual(credentialRows?.count, 2)

        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), appKey)
        XCTAssertEqual(try identifiers(opened.store), Self.currentIdentifiers)
        XCTAssertEqual(try existingLegacyTables(opened.store), [])
        XCTAssertEqual(try opened.store.db.read { try CurrentLibrarySchema.opening($0) }, .current)
        let vault = Vault(store: opened.store, key: opened.key)
        try vault.beginManagementSession(using: .allow)
        let listed = try vault.listTextCredentials()
        XCTAssertEqual(Set(listed.map(\.name)), Set(expected.keys))
        for credential in listed {
            XCTAssertEqual(try vault.revealTextCredential(id: credential.id, using: .allow).value,
                           expected[credential.name])
        }
        vault.lock()
        try opened.store.close()
        XCTAssertEqual(try allDataRows(paths.currentDatabase)["credentials"], credentialRows)
        XCTAssertEqual(keys.appKey, appKey)
        XCTAssertNil(keys.pendingKey)

        let reopened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(try identifiers(reopened.store), Self.currentIdentifiers)
        try reopened.store.close()
    }

    func testPendingKeyWithCredentialRowAtBaselineFailsWithoutChangingAnyFileOrKey() throws {
        try assertPendingRejected(baselineOnly: true, error: .missingKey) { paths, pending in
            try self.insertAuthenticatedCredential(into: paths, key: pending)
        }
    }

    func testPendingKeyWithKeptLegacyTablesFailsWithoutChangingAnyFileOrKey() throws {
        try assertPendingRejected(
            baselineOnly: true,
            sql: "INSERT INTO grdb_migrations VALUES ('askkey-0002-drop-legacy-tables')", error: .missingKey)
    }

    func testPendingKeyWithNonUUIDActiveProjectAfterDropFailsWithoutChangingAnyFileOrKey() throws {
        try assertPendingRejected(sql: "UPDATE config SET value = lower(value) WHERE key = 'active_project_id'",
                                  error: .missingKey)
    }

    static let currentHistorySQL = """
        DELETE FROM grdb_migrations;
        INSERT INTO grdb_migrations VALUES ('askkey-0001-baseline');
        INSERT INTO grdb_migrations VALUES ('askkey-0002-drop-legacy-tables');
        """

    static let dropLegacyTablesSQL = """
        DROP TABLE secret_values; DROP TABLE secrets; DROP TABLE environments;
        DROP TABLE projects; DROP TABLE activity_log;
        """

    /// Adoption must keep every legacy table and row when they may hold user
    /// data, record the drop migration anyway, and reopen without changes.
    func assertLegacyTablesKept(sql: String, foreignKeysEnabled: Bool = true) throws {
        let (paths, keys) = try fixtureLibrary()
        var configuration = Configuration()
        configuration.foreignKeysEnabled = foreignKeysEnabled
        let database = try DatabaseQueue(path: paths.currentDatabase.path, configuration: configuration)
        try database.write { try $0.execute(sql: sql) }
        try database.close()
        let original = try allDataRows(paths.currentDatabase)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(try identifiers(opened.store), Self.currentIdentifiers)
        XCTAssertEqual(try existingLegacyTables(opened.store), CurrentLibrarySchema.legacyTables.sorted())
        try verifyManifest(store: opened.store, key: opened.key, directory: paths.directory, legacyRowsKept: true)
        try opened.store.close()
        XCTAssertEqual(try allDataRows(paths.currentDatabase), original)
        XCTAssertEqual(keys.mutations, 1, "only the best-effort deletePendingKey")

        let before = try directoryBytes(paths.directory)
        let reopened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(try identifiers(reopened.store), Self.currentIdentifiers)
        try reopened.store.close()
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(try allDataRows(paths.currentDatabase), original)
        XCTAssertEqual(keys.mutations, 2)
    }

    func insertAuthenticatedCredential(into paths: VaultBootstrapPaths, key pending: Data) throws {
        // Created in a separate library with the same key, then copied in, so
        // the unfinished database is never migrated by this setup.
        let source = try temporaryDirectory().appendingPathComponent("SYNTHETIC-source.db")
        let store = try VaultStore(path: source.path)
        let key = VaultCrypto.keyFromData(pending)
        store.bindCredentialAuthenticationKey(key)
        _ = try Vault(store: store, key: key).createTextCredential(
            .init(name: "SYNTHETIC-TOKEN", value: "synthetic", environmentVariable: "SYNTHETIC_TOKEN",
                  permission: .allowed), using: .deny)
        try store.close()
        let database = try DatabaseQueue(path: paths.currentDatabase.path)
        defer { try? database.close() }
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS source", arguments: [source.path])
            try db.execute(sql: "INSERT INTO credentials SELECT * FROM source.credentials")
            try db.execute(sql: "DETACH DATABASE source")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM credentials"), 1)
        }
    }

    /// Produces the unfinished first creation that the baseline-only code
    /// (before askkey-0002 existed) leaves behind: `[baseline]` with its seed.
    func unfinishedBaselineCreation() throws -> (VaultBootstrapPaths, MemoryAppKeyStore) {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        keys.pendingKey = VaultCrypto.keyToData(VaultCrypto.generateKey())
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.prepareDatabase { database in
            // Like VaultStore: SQLite removes its WAL sidecars on close.
            var persistWAL: CInt = 0
            _ = sqlite3_file_control(database.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, &persistWAL)
        }
        let database = try DatabaseQueue(path: paths.currentDatabase.path, configuration: configuration)
        try CurrentLibrarySchema.migrator().migrate(database, upTo: CurrentLibrarySchema.baselineIdentifier)
        try database.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.currentDatabase.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.directory.path), ["credentials-v2.db"])
        return (paths, keys)
    }

    func existingLegacyTables(_ store: VaultStore) throws -> [String] {
        try store.db.read { db in
            try CurrentLibrarySchema.legacyTables.filter { try db.tableExists($0) }.sorted()
        }
    }

    func v15SchemaWithoutLegacyTables() throws -> [String] {
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        return try expected.write { db in
            try db.execute(sql: String(contentsOf: fixture("schema.sql"), encoding: .utf8))
            try db.execute(sql: Self.dropLegacyTablesSQL)
            return try CurrentLibrarySchema.normalizedSchema(db)
        }
    }
}
