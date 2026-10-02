import Foundation
import GRDB
import XCTest
@testable import AskKeyCore

/// askkey-0002-drop-legacy-tables (#33): opening states after the drop
/// migration, kept legacy data, and unfinished first creations on either
/// side of it. Uses the v15 fixture helpers of `CurrentLibraryAdoptionTests`.
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

    func testPendingKeyIsPromotedForCreationInterruptedBetweenMigrations() throws {
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
    func assertLegacyTablesKept(sql: String) throws {
        let (paths, keys) = try fixtureLibrary()
        let database = try DatabaseQueue(path: paths.currentDatabase.path)
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

    /// Produces a first creation interrupted between the baseline and the drop
    /// migration (also the state the baseline-only code leaves behind).
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
