import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class CurrentLibraryAdoptionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testNewLibraryMatchesV15Schema() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        defer { try? opened.store.close() }
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try expected.write { try $0.execute(sql: String(contentsOf: fixture("schema.sql"), encoding: .utf8)) }
        XCTAssertEqual(try opened.store.db.read { try CurrentLibrarySchema.normalizedSchema($0) },
                       try expected.read { try CurrentLibrarySchema.normalizedSchema($0) })
        XCTAssertEqual(try identifiers(opened.store), ["askkey-0001-baseline"])
        XCTAssertEqual(try opened.store.fetchAllProjects().count, 1)
        XCTAssertEqual(keys.appKey?.count, 32)
        XCTAssertNil(keys.pendingKey)
    }

    func testAdoptionPreservesEveryManifestItemAndAllOtherRowsAndSecondOpenChangesNothing() throws {
        XCTAssertFalse(KeychainQuery.systemKeychainAllowed)
        let (paths, keys) = try fixtureLibrary()
        let original = try allDataRows(paths.currentDatabase)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try verifyManifest(store: opened.store, key: opened.key, directory: paths.directory)
        XCTAssertEqual(try identifiers(opened.store), ["askkey-0001-baseline"])
        try opened.store.close()
        XCTAssertEqual(try allDataRows(paths.currentDatabase), original)
        XCTAssertEqual(keys.mutations, 0)
        let before = try directoryBytes(paths.directory)
        let second = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try second.store.close()
        let after = try directoryBytes(paths.directory)
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for name in before.keys { XCTAssertEqual(after[name], before[name], name) }
        XCTAssertEqual(keys.mutations, 0)
    }

    func testAdoptionIgnoresHistoricalSiblingsAndPendingFiles() throws {
        let (paths, keys) = try fixtureLibrary()
        let siblings = ["vault.db", "credentials.db", "migration-v2.journal", "migration.journal",
                        "credentials-v2.db.pending-shm", "credentials-v2.db.pending-wal",
                        "credentials-v2.db.pending", "migration-unknown.journal"]
        for name in siblings {
            let bytes = name.contains("pending") ? Data() : Data("SYNTHETIC-opaque-\(name)".utf8)
            try bytes.write(to: paths.directory.appendingPathComponent(name))
        }
        let before = try directoryBytes(paths.directory)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try opened.store.close()
        let after = try directoryBytes(paths.directory)
        for name in siblings { XCTAssertEqual(after[name], before[name], name) }
        XCTAssertEqual(keys.mutations, 0)
    }

    func testUnknownExtraIdentifierFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "INSERT INTO grdb_migrations VALUES ('unknown')", error: .unsupportedMigrations)
    }

    func testMissingLegacyIdentifierFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'", error: .unsupportedMigrations)
    }

    func testMissingMigrationTableFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "DROP TABLE grdb_migrations", error: .unsupportedMigrations)
    }

    func testExtraColumnFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "ALTER TABLE credentials ADD COLUMN unknown TEXT", error: .schemaMismatch)
    }

    func testExtraTriggerFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "CREATE TRIGGER unknown AFTER DELETE ON grdb_migrations BEGIN DELETE FROM credentials; END",
                           error: .schemaMismatch)
    }

    func testSQLiteLikeUserTableFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "CREATE TABLE sqliteExtra (value TEXT)", error: .schemaMismatch)
    }

    func testUnexpectedSQLiteStatisticsTableFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: "ANALYZE", error: .schemaMismatch)
    }

    func testBaselineWithSchemaMismatchFailsWithoutChangingAnyFile() throws {
        try assertRejected(sql: """
            DELETE FROM grdb_migrations;
            INSERT INTO grdb_migrations VALUES ('askkey-0001-baseline');
            ALTER TABLE config ADD COLUMN unknown TEXT;
            """, error: .schemaMismatch)
    }

    func testDatabaseWithoutAppKeyRejectsPendingFallbackAndChangesNoFile() throws {
        let (paths, keys) = try fixtureLibrary()
        keys.pendingKey = keys.appKey
        keys.appKey = nil
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingKey)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
        XCTAssertNotNil(keys.pendingKey)
    }

    func testDatabaseWithoutAnyKeyFailsWithoutChangingAnyFile() throws {
        let (paths, _) = try fixtureLibrary()
        let keys = MemoryAppKeyStore()
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingKey)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testRollbackJournalFailsWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        try Data("SYNTHETIC-unknown-journal".utf8).write(to: URL(fileURLWithPath: paths.currentDatabase.path + "-journal"))
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidState)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testSymbolicLinkDatabaseFailsWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        let target = paths.directory.appendingPathComponent("SYNTHETIC-target.db")
        try FileManager.default.moveItem(at: paths.currentDatabase, to: target)
        try FileManager.default.createSymbolicLink(at: paths.currentDatabase, withDestinationURL: target)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidState)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testInvalidKeyFailsWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        keys.appKey = Data(repeating: 1, count: 31)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidKey)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testWrongKeyFailsBeforeAdoptionWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        keys.appKey = Data(repeating: 1, count: 32)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testUnauthenticatedCredentialFailsBeforeAdoptionWithoutChangingAnyFile() throws {
        try assertRejected(sql: "UPDATE credentials SET authentication_tag = NULL", error: nil)
    }

    func testUnknownIdentifierInLiveWALFailsWithoutChangingDatabaseOrSidecars() throws {
        let (paths, keys) = try fixtureLibrary()
        var configuration = Configuration()
        configuration.journalMode = .wal
        let writer = try DatabaseQueue(path: paths.currentDatabase.path, configuration: configuration)
        defer { try? writer.close() }
        try writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('unknown-wal')") }
        let before = try directoryBytes(paths.directory)
        XCTAssertNotNil(before["credentials-v2.db-wal"])
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .unsupportedMigrations)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testNormalizationPreservesQuotedValues() {
        XCTAssertEqual(CurrentLibrarySchema.normalizeSQL("CREATE  TABLE \"x\" (v TEXT DEFAULT 'a b')"),
                       CurrentLibrarySchema.normalizeSQL("create table \"x\"(v text default 'a b')"))
        XCTAssertNotEqual(CurrentLibrarySchema.normalizeSQL("DEFAULT 'a b'"),
                          CurrentLibrarySchema.normalizeSQL("DEFAULT 'ab'"))
        XCTAssertNotEqual(CurrentLibrarySchema.normalizeSQL("DEFAULT 'A'"),
                          CurrentLibrarySchema.normalizeSQL("DEFAULT 'a'"))
        XCTAssertNotEqual(CurrentLibrarySchema.normalizeSQL("v TEXT NOT NULL"),
                          CurrentLibrarySchema.normalizeSQL("v TEXTNOT NULL"))
    }

    private func assertRejected(sql: String, error: VaultBootstrapError?) throws {
        let (paths, keys) = try fixtureLibrary()
        let database = try DatabaseQueue(path: paths.currentDatabase.path)
        try database.write { try $0.execute(sql: sql) }
        try database.close()
        try Data("SYNTHETIC-sibling".utf8).write(to: paths.directory.appendingPathComponent("vault.db"))
        try Data().write(to: paths.directory.appendingPathComponent("credentials-v2.db.pending-wal"))
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            if let error { XCTAssertEqual($0 as? VaultBootstrapError, error) }
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.mutations, 0)
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/v15"))
    }

    private func fixtureLibrary() throws -> (VaultBootstrapPaths, MemoryAppKeyStore) {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        try FileManager.default.copyItem(at: fixture("library.db"), to: paths.currentDatabase)
        return (paths, MemoryAppKeyStore(appKey: try Data(contentsOf: fixture("library.key"))))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyAdoption-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func identifiers(_ store: VaultStore) throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
    }

    private func allDataRows(_ source: URL) throws -> [String: [Row]] {
        try CurrentLibrarySnapshot.withCopy(of: source) { snapshot in
            let database = try DatabaseQueue(path: snapshot.path)
            defer { try? database.close() }
            return try database.read { db in
                let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*' AND name != 'grdb_migrations' ORDER BY name")
                return try Dictionary(uniqueKeysWithValues: tables.map { table in
                    (table, try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY rowid"))
                })
            }
        }
    }

    private func verifyManifest(store: VaultStore, key: SymmetricKey, directory: URL) throws {
        let manifest = try JSONDecoder().decode(V15Manifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let deliveries = try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries"))
        let clock = now
        let vault = Vault(store: store, key: key, now: { clock },
                          approvalRequests: BrokerApprovalStateMachine(clock: { clock }, authenticate: { _ in true }),
                          fileDeliveryManager: deliveries)
        defer { vault.lock(); deliveries.cleanupAll() }
        try vault.beginManagementSession(using: .allow)
        let active = try vault.listTextCredentials()
        let credentials = try (active + vault.listRecycledTextCredentials()).map {
            V15Credential(id: $0.id, name: $0.name, kind: $0.payloadKind.rawValue,
                          permission: $0.permission.rawValue, group: $0.groupName, trashed: $0.deletedAt != nil,
                          expiry: $0.expiresAt.map { ISO8601DateFormatter().string(from: $0) })
        }.sorted { $0.name < $1.name }
        XCTAssertEqual(credentials, manifest.credentials)
        XCTAssertEqual(try vault.listCredentialGroups(), manifest.groups)
        XCTAssertEqual(try vault.listCredentialAccessRecords().sorted { $0.result.rawValue < $1.result.rawValue },
                       manifest.accessRecords)
        try store.db.read { db in
            for (table, count) in manifest.rowCounts {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\""),
                               table == "grdb_migrations" ? 1 : count, table)
            }
            let writes = try Row.fetchAll(db, sql: "SELECT * FROM agent_write_operations ORDER BY operation_id").map { row in
                V15Write(operationID: row["operation_id"], credentialID: row["credential_id"],
                         operation: row["operation"], requestID: row["request_id"],
                         payloadDigest: row["payload_digest"], capabilityDigest: row["capability_digest"],
                         resultDigest: row["result_digest"], committedAt: row["committed_at"])
            }
            XCTAssertEqual(writes, manifest.writeOperations)
        }
        for credential in active {
            let item = try vault.revealTextCredential(id: credential.id, using: .allow)
            XCTAssertTrue(item.privateNotes?.hasPrefix("SYNTHETIC-") == true)
            if item.payloadKind == .text {
                let expected = item.name == "SYNTHETIC-Text-1" ? "SYNTHETIC-Agent-Modified-Value"
                    : "SYNTHETIC-Value-\(item.name.suffix(1))"
                XCTAssertEqual(item.value, expected)
            } else {
                XCTAssertTrue(try XCTUnwrap(item.originalFilename).hasPrefix("SYNTHETIC-"))
                let bytes = try XCTUnwrap(item.fileBytes)
                XCTAssertEqual(bytes.count, item.byteSize)
                XCTAssertEqual(item.contentDigest, Data(SHA256.hash(data: bytes)).map { String(format: "%02x", $0) }.joined())
                if item.name == "SYNTHETIC-Binary-File" {
                    XCTAssertEqual(bytes, Data("SYNTHETIC-Binary-Receipt".utf8) + Data([0, 1, 2, 3, 255, 128]))
                } else {
                    XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("-----BEGIN PRIVATE KEY-----"))
                }
            }
        }
        let allFields = try XCTUnwrap(active.first { $0.name == "SYNTHETIC-Text-2" })
        let revealed = try vault.revealTextCredential(id: allFields.id, using: .allow)
        XCTAssertEqual(revealed.usageInstructions, "SYNTHETIC-Usage-2")
        XCTAssertEqual(revealed.privateNotes, "SYNTHETIC-Notes-2")
        XCTAssertEqual(revealed.environmentVariable, "SYNTHETIC_ENV_ALL_FIELDS")
        XCTAssertEqual(try store.fetchRecycledCredentials().map { try VaultCrypto.decrypt($0.encryptedPayload, using: key) },
                       ["SYNTHETIC-Trashed-Value"])
    }
}

private struct V15Manifest: Decodable {
    let rowCounts: [String: Int]
    let credentials: [V15Credential]
    let groups: [String]
    let accessRecords: [CredentialAccessEvent]
    let writeOperations: [V15Write]
}

private struct V15Credential: Decodable, Equatable {
    let id: String
    let name: String
    let kind: String
    let permission: String
    let group: String?
    let trashed: Bool
    let expiry: String?
}

private struct V15Write: Decodable, Equatable {
    let operationID: String
    let credentialID: String
    let operation: String
    let requestID: String
    let payloadDigest: String
    let capabilityDigest: String
    let resultDigest: String?
    let committedAt: String
}
