import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ComponentMetadataMigrationTests: AgentTextWriteTestSupport {
    func testV032LibraryMigratesOldTagsThenBackfillsAllRowsWithoutChangingCatalogBytes() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let catalog = try encoder.encode(harness.vault.brokerCredentialCatalog())
        let records = try legacyRecords(harness)
        let url = try legacyLibrary(records, harness: harness)
        let migrated = try VaultStore(path: url.path, authenticationKey: harness.key)
        defer { try? migrated.close() }
        let reopened = Vault(store: migrated, key: harness.key)
        XCTAssertFalse(reopened.isLocked)
        XCTAssertNil(reopened.componentMetadataIssue)
        XCTAssertEqual(try encoder.encode(reopened.brokerCredentialCatalog()), catalog)
        let after = try migrated.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }
        XCTAssertEqual(after.count, records.count)
        XCTAssertEqual(after.filter { $0.deletedAt != nil }.count, 1)
        for (before, current) in zip(records, after) {
            XCTAssertNotNil(current.encryptedComponentMetadata)
            try CredentialRecordAuthentication.verify(current, using: harness.key)
            XCTAssertEqual(current.encryptedPayload, before.encryptedPayload)
            XCTAssertEqual(current.updatedAt, before.updatedAt)
            XCTAssertEqual(current.createdAt, before.createdAt)
            XCTAssertNotEqual(current.authenticationTag, before.authenticationTag)
        }
        let completed = try encoder.encode(after)
        let marker = try migrated.configValue(key: VaultStore.componentMetadataCompletionKey)
        XCTAssertNotNil(marker)
        try migrated.prepareComponentMetadata(using: harness.key)
        XCTAssertEqual(try encoder.encode(migrated.db.read { try CredentialRecord.order(Column("id")).fetchAll($0) }), completed)
        XCTAssertEqual(try migrated.configValue(key: VaultStore.componentMetadataCompletionKey), marker)
    }

    func testOldAuthenticatedEncodingOmitsNilMetadataAndProtectsNewField() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let old = try XCTUnwrap(legacyRecords(harness).first)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var unsigned = old
        unsigned.authenticationTag = nil
        let encoded = try encoder.encode(unsigned)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("encrypted_component_metadata"))
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

    func testMigrationInterruptionRollsBackSchemaRowsHistoryAndMarkerThenRetryIsIdempotent() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let records = try legacyRecords(harness)
        let url = try legacyLibrary(records, harness: harness)
        let database = try DatabaseQueue(path: url.path)
        defer { try? database.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try database.write { db in
            // TEMP triggers do not change the supported on-disk schema.
            try db.execute(sql: """
                CREATE TEMP TABLE backfill_updates (count INTEGER);
                INSERT INTO backfill_updates VALUES (0);
                CREATE TEMP TRIGGER interrupt_component_backfill BEFORE UPDATE ON credentials
                WHEN (SELECT count FROM backfill_updates) = 1
                BEGIN SELECT RAISE(ABORT, 'synthetic interruption'); END;
                CREATE TEMP TRIGGER count_component_backfill AFTER UPDATE ON credentials
                BEGIN UPDATE backfill_updates SET count = count + 1; END
                """)
        }
        XCTAssertThrowsError(try CurrentLibrarySchema.migrator(componentMetadataKey: harness.key).migrate(database))
        try database.read { db in
            XCTAssertEqual(try CurrentLibrarySchema.opening(db), .preMetadata)
            try Self.v032HistoryGate(db)
            XCTAssertEqual(try encoder.encode(CredentialRecord.order(Column("id")).fetchAll(db)), try encoder.encode(records))
            XCTAssertNil(try ConfigRecord.fetchOne(db, key: VaultStore.componentMetadataCompletionKey))
        }
        try database.write { try $0.execute(sql: "DROP TRIGGER interrupt_component_backfill") }
        try CurrentLibrarySchema.migrator(componentMetadataKey: harness.key).migrate(database)
        let completed = try database.read { try encoder.encode(CredentialRecord.order(Column("id")).fetchAll($0)) }
        try CurrentLibrarySchema.migrator(componentMetadataKey: harness.key).migrate(database)
        XCTAssertEqual(try database.read { try encoder.encode(CredentialRecord.order(Column("id")).fetchAll($0)) }, completed)
    }

    func testHistoricalHiddenAndRecycledOversizedTextAndLongFileNamesStayManageable() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let base = try legacyRecords(harness)
        var records: [CredentialRecord] = []
        for recycled in [false, true] {
            var text = try XCTUnwrap(base.first { $0.payloadKind == "text" && $0.deletedAt == nil })
            text.id = UUID().uuidString
            text.permission = CredentialPermission.hidden.rawValue
            text.encryptedPayload = try VaultCrypto.encrypt(String(repeating: "X", count: 5 * 1024 * 1024 + 1), using: harness.key)
            records.append(try historical(text, named: "Large text \(recycled)", recycled: recycled, key: harness.key))
            for length in [256, 4096] {
                var file = try XCTUnwrap(base.first { $0.payloadKind == "file" })
                file.id = UUID().uuidString
                file.permission = CredentialPermission.hidden.rawValue
                file.encryptedOriginalFilename = try VaultCrypto.encrypt(String(repeating: "F", count: length), using: harness.key)
                records.append(try historical(file, named: "Long filename \(length) \(recycled)", recycled: recycled, key: harness.key))
            }
        }
        // A malformed material encoding is deliberately ignored by the bundle
        // projection decoder; it reads only the enum case, names and delivery.
        var bundle = try XCTUnwrap(base.first { $0.payloadKind == "bundle" })
        bundle.encryptedPayload = try VaultCrypto.encrypt(
            #"[{"name":"Token","value":{"text":{"ignored":true}},"delivery":{"environmentVariable":{"_0":"TOKEN"}}}]"#,
            using: harness.key)
        records.append(bundle)
        let url = try legacyLibrary(records, harness: harness)
        let store = try VaultStore(path: url.path, authenticationKey: harness.key)
        defer { try? store.close() }
        let vault = Vault(store: store, key: harness.key)
        XCTAssertFalse(vault.isLocked)
        XCTAssertNil(vault.componentMetadataIssue)
        // Remove only the intentionally malformed bundle fixture before asking
        // management to decode its full material (outside backfill's contract).
        try store.deleteCredential(id: bundle.id)
        try vault.beginManagementSession(using: .allow)
        XCTAssertEqual(try vault.listTextCredentials().count, 3)
        XCTAssertEqual(try vault.listRecycledTextCredentials().count, 3)
        for record in try store.fetchAllCredentials() {
            let revealed = try vault.revealTextCredential(id: record.id, using: .allow)
            if record.payloadKind == "text" { XCTAssertEqual(revealed.value?.utf8.count, 5 * 1024 * 1024 + 1) }
            else { XCTAssertTrue([256, 4096].contains(revealed.originalFilename?.utf8.count ?? 0)) }
        }
    }

    func testFailedUpgradeLeavesV032OpenableAndManagementCanRepairCreateRecycleAndDelete() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        var broken = try XCTUnwrap(legacyRecords(harness).first { $0.payloadKind == "bundle" })
        let components = [CredentialComponentInput(name: "Token", value: .text("synthetic-private-value"),
            delivery: .environmentVariable("PRIVATE_MAPPING\n"))]
        broken.encryptedPayload = try VaultCrypto.encrypt(JSONEncoder().encode(components), using: harness.key)
        let url = try legacyLibrary([broken], harness: harness)
        let store = try VaultStore(path: url.path, authenticationKey: harness.key)
        let vault = Vault(store: store, key: harness.key)
        XCTAssertFalse(vault.isLocked)
        let issue = try XCTUnwrap(vault.componentMetadataIssue)
        XCTAssertEqual(issue.reason, .backfill)
        XCTAssertEqual(issue.credentialNames, ["Bundle"])
        XCTAssertFalse(issue.localizedDescription.contains("synthetic-private-value"))
        XCTAssertFalse(issue.localizedDescription.contains("PRIVATE_MAPPING"))
        XCTAssertFalse(try vault.agentAccessPolicyState().needsRecovery)
        XCTAssertThrowsError(try vault.brokerCredentialCatalog()) { XCTAssertTrue($0 is ComponentMetadataUpgradeError) }
        try store.db.read(Self.v032HistoryGate)
        try vault.beginManagementSession(using: .allow)
        XCTAssertEqual(try vault.listTextCredentials().count, 1)
        XCTAssertEqual(try vault.revealTextCredential(id: broken.id, using: .allow).components.first?.value, .text("synthetic-private-value"))
        _ = try vault.updateBundleCredential(id: broken.id,
            .init(name: "Bundle", components: [.init(name: "Token", value: .text("synthetic-fixed"))]), using: .allow)
        let created = try vault.createTextCredential(.init(name: "New", value: "synthetic-new"), using: .allow)
        try store.recycleCredential(id: created.id, deletedAt: "2026-01-01T00:00:00Z")
        try store.restoreCredential(id: created.id)
        try store.deleteCredential(id: created.id)
        try store.db.read { db in
            try Self.v032HistoryGate(db)
            for record in try CredentialRecord.fetchAll(db) {
                XCTAssertNil(record.encryptedComponentMetadata)
                try CredentialRecordAuthentication.verify(record, using: harness.key)
            }
        }
        XCTAssertThrowsError(try vault.brokerCredentialCatalog())
        try store.close()
        let retry = try VaultStore(path: url.path, authenticationKey: harness.key)
        defer { try? retry.close() }
        let reopened = Vault(store: retry, key: harness.key)
        XCTAssertNil(reopened.componentMetadataIssue)
        XCTAssertEqual(try reopened.brokerCredentialCatalog().count, 1)
    }

    func testSingleMaterialBackfillNeverDecryptsPayloadOrFilename() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let records = try legacyRecords(harness).filter { $0.payloadKind != "bundle" }.map { old in
            var record = old
            record.encryptedPayload = Data("synthetic-payload-decryption-tripwire".utf8)
            record.encryptedOriginalFilename = Data("synthetic-filename-decryption-tripwire".utf8)
            return record
        }
        let url = try legacyLibrary(records, harness: harness)
        let store = try VaultStore(path: url.path, authenticationKey: harness.key)
        defer { try? store.close() }
        let vault = Vault(store: store, key: harness.key)
        XCTAssertNil(vault.componentMetadataIssue)
        try vault.beginManagementSession(using: .allow)
        XCTAssertEqual(try vault.listTextCredentials().count, 2)
        XCTAssertEqual(try vault.brokerCredentialCatalog().count, 2)
        for record in try store.fetchAllCredentialsIncludingRecycled() {
            XCTAssertNotNil(record.encryptedComponentMetadata)
            XCTAssertEqual(record.encryptedPayload, Data("synthetic-payload-decryption-tripwire".utf8))
            XCTAssertEqual(record.encryptedOriginalFilename, Data("synthetic-filename-decryption-tripwire".utf8))
        }
    }

    func testCompletionMarkerRejectsOldAuthenticatedRowInsteadOfRebackfilling() throws {
        let harness = try makeHarness { _ in true }
        _ = try createLegacyMaterials(in: harness)
        let old = try XCTUnwrap(legacyRecords(harness).first)
        // Restore a complete historical, correctly authenticated row without
        // metadata; this cannot be detected by the row HMAC alone.
        try harness.store.updateCredential(old)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(harness.store.fetchAllCredentialsIncludingRecycled())
        let reopened = Vault(store: harness.store, key: harness.key)
        XCTAssertFalse(reopened.isLocked)
        XCTAssertEqual(reopened.componentMetadataIssue?.reason, .integrity)
        XCTAssertEqual(try encoder.encode(harness.store.fetchAllCredentialsIncludingRecycled()), before)
        XCTAssertThrowsError(try reopened.brokerCredentialCatalog())
        XCTAssertFalse(try reopened.agentAccessPolicyState().needsRecovery)
    }

    func testMissingCorruptOrWrongKeyCompletionMarkerUsesSpecificIntegrityError() throws {
        for variant in ["missing", "corrupt", "wrong-key"] {
            let harness = try makeHarness { _ in true }
            let value: String? = variant == "missing" ? nil : variant == "wrong-key"
                ? try VaultCrypto.encrypt("AskKey component metadata complete v1", using: VaultCrypto.generateKey()).base64EncodedString()
                : "synthetic-invalid-marker"
            try harness.store.setConfigValue(key: VaultStore.componentMetadataCompletionKey, value: value)
            let store = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
            defer { try? store.close() }
            XCTAssertEqual(store.componentMetadataIssue?.reason, .integrity)
            XCTAssertEqual(try store.configValue(key: VaultStore.componentMetadataCompletionKey), value)
            let vault = Vault(store: store, key: harness.key)
            XCTAssertFalse(vault.isLocked)
            try vault.beginManagementSession(using: .allow)
            XCTAssertNoThrow(try vault.listTextCredentials())
            XCTAssertThrowsError(try vault.brokerCredentialCatalog()) { XCTAssertTrue($0 is ComponentMetadataUpgradeError) }
        }
    }

    func testV032HistoryGateRefusesSuccessfullyMigratedLibraryWithoutMutatingIt() throws {
        let harness = try makeHarness { _ in true }
        let before = try harness.databaseBytes()
        XCTAssertThrowsError(try harness.store.db.read(Self.v032HistoryGate)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .unsupportedMigrations)
        }
        XCTAssertEqual(try harness.databaseBytes(), before)
    }

    func testCompletedEmptyLibraryWithoutItsKeyCannotBeDiscardedAsFirstCreation() throws {
        let harness = try makeHarness { _ in true }
        let paths = VaultBootstrapPaths(directory: harness.databaseURL.deletingLastPathComponent().appendingPathComponent("bootstrap"))
        let keys = MemoryAppKeyStore()
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertNil(opened.store.componentMetadataIssue)
        try opened.store.close()
        let before = try Data(contentsOf: paths.currentDatabase)
        keys.pendingKey = keys.appKey
        keys.appKey = nil
        let mutations = keys.mutations
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingKey)
        }
        XCTAssertEqual(try Data(contentsOf: paths.currentDatabase), before)
        XCTAssertEqual(keys.mutations, mutations)
        XCTAssertNotNil(keys.pendingKey)
    }

    private static func v032HistoryGate(_ db: Database) throws {
        // Freeze v0.3.2's accepted identifiers independently of current schema.
        let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        let baseline = "askkey-0001-baseline"
        let legacy = ["v1", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11",
                      "v12-remove-folder-associations", "v13-remove-project-path",
                      "v14-authenticated-credentials", "v15-file-write-receipts"]
        guard identifiers == [baseline] || identifiers == legacy || identifiers == [baseline, "askkey-0002-drop-legacy-tables"] else {
            throw VaultBootstrapError.unsupportedMigrations
        }
    }

    private func legacyRecords(_ harness: Harness) throws -> [CredentialRecord] {
        try harness.store.db.read { db in
            try CredentialRecord.order(Column("id")).fetchAll(db).map {
                var record = $0
                record.encryptedComponentMetadata = nil
                return try CredentialRecordAuthentication.seal(record, using: harness.key)
            }
        }
    }

    private func legacyLibrary(_ records: [CredentialRecord], harness: Harness) throws -> URL {
        let url = harness.databaseURL.deletingLastPathComponent().appendingPathComponent("v032-\(UUID().uuidString).db")
        let database = try DatabaseQueue(path: url.path)
        defer { try? database.close() }
        try CurrentLibrarySchema.migrator().migrate(database, upTo: CurrentLibrarySchema.dropLegacyTablesIdentifier)
        try database.write { db in
            for var record in records {
                record.encryptedComponentMetadata = nil
                record.includesComponentMetadataColumn = false
                try CredentialRecordAuthentication.seal(record, using: harness.key).insert(db)
            }
        }
        return url
    }

    private func historical(_ record: CredentialRecord, named name: String, recycled: Bool, key: SymmetricKey) throws -> CredentialRecord {
        var record = record
        record.encryptedDisplayName = try VaultCrypto.encrypt(name, using: key)
        record.nameIndex = CredentialIndex.hash(normalizedName: CredentialName.normalized(name), vaultKey: key)
        record.deletedAt = recycled ? "2026-01-01T00:00:00Z" : nil
        return record
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
