import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ComponentMetadataMigrationTests: AgentTextWriteTestSupport {
    func testV032LibraryMigratesOldTagsThenBackfillsAllRowsWithoutChangingCatalogBytes() throws {
        let harness = try makeHarness { _ in true }
        let ids = try createLegacyMaterials(in: harness)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let beforeCatalog = try encoder.encode(harness.vault.brokerCredentialCatalog())
        try stripMetadata(in: harness)
        let old = try harness.store.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }
        let legacyURL = harness.databaseURL.deletingLastPathComponent().appendingPathComponent("v032.db")
        let legacy = try DatabaseQueue(path: legacyURL.path)
        try CurrentLibrarySchema.migrator().migrate(legacy, upTo: CurrentLibrarySchema.dropLegacyTablesIdentifier)
        try legacy.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS source", arguments: [harness.databaseURL.path])
            let columns = try db.columns(in: "credentials").map { $0.name.quotedDatabaseIdentifier }.joined(separator: ", ")
            try db.execute(sql: "INSERT INTO credentials (\(columns)) SELECT \(columns) FROM source.credentials")
            try db.execute(sql: "DETACH DATABASE source")
            XCTAssertEqual(try CurrentLibrarySchema.opening(db), .preMetadata)
            for record in try CredentialRecord.fetchAll(db) {
                XCTAssertNil(record.encryptedComponentMetadata)
                try CredentialRecordAuthentication.verify(record, using: harness.key)
            }
        }
        try legacy.close()

        let migrated = try VaultStore(path: legacyURL.path, authenticationKey: harness.key)
        migrated.bindCredentialAuthenticationKey(harness.key)
        defer { try? migrated.close() }
        let beforeBackfill = try migrated.db.read { db in
            XCTAssertEqual(try CurrentLibrarySchema.opening(db), .current)
            XCTAssertTrue(try db.columns(in: "credentials").contains { $0.name == "encrypted_component_metadata" && !$0.isNotNull })
            return try CredentialRecord.order(Column("id")).fetchAll(db)
        }
        XCTAssertEqual(try encoder.encode(beforeBackfill), try encoder.encode(old), "Schema upgrade preserves old authenticated bytes")
        for record in beforeBackfill { try CredentialRecordAuthentication.verify(record, using: harness.key) }

        let reopened = Vault(store: migrated, key: harness.key)
        XCTAssertFalse(reopened.isLocked)
        XCTAssertEqual(try encoder.encode(reopened.brokerCredentialCatalog()), beforeCatalog)
        let after = try migrated.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }
        XCTAssertEqual(after.count, ids.count)
        XCTAssertEqual(after.filter { $0.deletedAt != nil }.count, 1)
        for (before, current) in zip(beforeBackfill, after) {
            XCTAssertNotNil(current.encryptedComponentMetadata)
            try CredentialRecordAuthentication.verify(current, using: harness.key)
            XCTAssertEqual(current.encryptedPayload, before.encryptedPayload)
            XCTAssertEqual(current.updatedAt, before.updatedAt)
            XCTAssertEqual(current.createdAt, before.createdAt)
            XCTAssertNotEqual(current.authenticationTag, before.authenticationTag)
        }
        let completed = try encoder.encode(after)
        try migrated.backfillComponentMetadata(using: harness.key) { _ in
            XCTFail("Idempotent backfill must not reopen any payload")
            throw SyntheticPolicyFailure()
        }
        XCTAssertEqual(try encoder.encode(migrated.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }), completed)
    }

    func testOldAuthenticatedEncodingOmitsNilMetadataAndProtectsNewField() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        try stripMetadata(in: harness)
        let old = try XCTUnwrap(harness.store.fetchAllCredentials().first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var unsigned = old
        unsigned.authenticationTag = nil
        let encoded = try encoder.encode(unsigned)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("encrypted_component_metadata"))
        // Independently reproduce the v0.3.2 HMAC domain and encoding.
        let authenticationKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: harness.key, salt: Data(),
            info: Data("AskKey credential authentication v1".utf8), outputByteCount: 32)
        let legacyTag = Data([1]) + Data(HMAC<SHA256>.authenticationCode(
            for: Data("AskKey credential record v1\0".utf8) + encoded, using: authenticationKey))
        XCTAssertEqual(old.authenticationTag, legacyTag)
        try CredentialRecordAuthentication.verify(old, using: harness.key)
        var changed = old
        changed.encryptedComponentMetadata = try CredentialComponentMetadata(singleKind: .text, mapping: "TOKEN").encrypted(using: harness.key)
        XCTAssertThrowsError(try CredentialRecordAuthentication.verify(changed, using: harness.key))
        changed = try CredentialRecordAuthentication.seal(changed, using: harness.key)
        changed.encryptedComponentMetadata = nil
        XCTAssertThrowsError(try CredentialRecordAuthentication.verify(changed, using: harness.key))
    }

    func testBackfillRollsBackEveryRowOnInterruptionAndRetryIsIdempotent() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        try stripMetadata(in: harness)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(harness.store.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) })
        // SQLite aborts the second row update, after one row was already written.
        try harness.store.db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER interrupt_component_backfill BEFORE UPDATE OF encrypted_component_metadata ON credentials
                WHEN (SELECT COUNT(*) FROM credentials WHERE encrypted_component_metadata IS NOT NULL) = 1
                BEGIN SELECT RAISE(ABORT, 'synthetic interruption'); END
                """)
        }
        XCTAssertThrowsError(try backfill(harness))
        XCTAssertEqual(try encoder.encode(harness.store.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }), before)
        try harness.store.db.write { try $0.execute(sql: "DROP TRIGGER interrupt_component_backfill") }
        try backfill(harness)
        XCTAssertTrue(try harness.store.db.read { try CredentialRecord.fetchAll($0) }.allSatisfy { $0.encryptedComponentMetadata != nil })
        try harness.store.backfillComponentMetadata(using: harness.key) { _ in
            XCTFail("Retry must not decrypt filled rows")
            throw SyntheticPolicyFailure()
        }
    }

    func testFailedReopenLeavesAgentAccessClosedUntilBackfillCanComplete() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        try stripMetadata(in: harness)
        try harness.store.db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER interrupt_reopening BEFORE UPDATE OF encrypted_component_metadata ON credentials
                BEGIN SELECT RAISE(ABORT, 'synthetic interruption'); END
                """)
        }
        let reopened = Vault(store: harness.store, key: harness.key)
        XCTAssertTrue(reopened.isLocked)
        XCTAssertThrowsError(try reopened.brokerCredentialCatalog())
        // The failed adoption closes the store; a fresh open can safely retry.
        let retryStore = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
        defer { try? retryStore.close() }
        let retry = Vault(store: retryStore, key: harness.key)
        XCTAssertFalse(retry.isLocked)
        XCTAssertEqual(try retry.brokerCredentialCatalog().count, 3)
    }

    func testV032HistoryGateRefusesMigratedLibraryWithoutMutatingIt() throws {
        let harness = try makeHarness { _ in true }
        let before = try harness.databaseBytes()
        XCTAssertThrowsError(try harness.store.db.read(Self.v032HistoryGate)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .unsupportedMigrations)
            XCTAssertEqual($0.localizedDescription,
                "The library has an unsupported migration history. Existing data was not changed.")
        }
        XCTAssertEqual(try harness.databaseBytes(), before)
    }

    /// Frozen migration-history gate from v0.3.2's CurrentLibrarySchema.opening.
    /// It rejects 0003 before the older schema or record decoder is reached.
    private static func v032HistoryGate(_ db: Database) throws {
        guard try db.tableExists("grdb_migrations") else { throw VaultBootstrapError.unsupportedMigrations }
        let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        let baselineIdentifier = "askkey-0001-baseline"
        let legacyIdentifiers = ["v1", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11",
                                "v12-remove-folder-associations", "v13-remove-project-path",
                                "v14-authenticated-credentials", "v15-file-write-receipts"]
        let currentIdentifiers = [baselineIdentifier, "askkey-0002-drop-legacy-tables"]
        guard identifiers == [baselineIdentifier] || identifiers == legacyIdentifiers || identifiers == currentIdentifiers else {
            throw VaultBootstrapError.unsupportedMigrations
        }
    }

    private func backfill(_ harness: Harness) throws {
        try harness.store.backfillComponentMetadata(using: harness.key) {
            try harness.vault.credentialComponents(from: $0, key: harness.key)
        }
    }

    private func stripMetadata(in harness: Harness) throws {
        let records = try harness.store.db.read { try CredentialRecord.fetchAll($0) }
        for var record in records {
            record.encryptedComponentMetadata = nil
            try harness.store.updateCredential(record)
        }
    }

    private func createLegacyMaterials(in harness: Harness) throws -> [String] {
        let text = try harness.vault.createTextCredential(
            .init(name: "Text", value: "synthetic-text", environmentVariable: String(repeating: "A", count: 256)), using: .allow)
        let file = try harness.vault.createFileCredential(.init(name: "File",
            snapshot: try .init(originalFilename: "synthetic.pem", bytes: Data("synthetic-file".utf8)),
            environmentVariable: "FILE_PATH"), using: .allow)
        let bundle = try harness.vault.createBundleCredential(.init(name: "Bundle", components: [
            .init(name: "Token", value: .text("synthetic-token"), delivery: .environmentVariable("TOKEN")),
            .init(name: "Undelivered", value: .text("synthetic-private"), delivery: .none)
        ]), using: .allow)
        let recycled = try harness.vault.createTextCredential(.init(name: "Recycled", value: "synthetic-recycled"), using: .allow)
        try harness.store.recycleCredential(id: recycled.id, deletedAt: "2026-01-01T00:00:00Z")
        return [text.id, file.id, bundle.id, recycled.id]
    }
}
