import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class ComponentMetadataCompletionMarkerTests: AgentTextWriteTestSupport {
    private let legacyMessage = "AskKey component metadata complete v1"

    func testValidV1UpgradesOnOpenWithoutChangingCredentialsOrMigrationHistory() throws {
        let harness = try makeHarness { _ in true }
        _ = try harness.vault.createTextCredential(.init(name: "Synthetic", value: "synthetic"), using: .allow)
        try installV1(in: harness.store, key: harness.key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let records = try encoder.encode(harness.store.fetchAllCredentialsIncludingRecycled())
        let history = try migrationHistory(harness.store)
        try harness.store.close()

        let opened = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
        XCTAssertNil(opened.componentMetadataIssue)
        let marker = try XCTUnwrap(opened.configValue(key: VaultStore.componentMetadataCompletionKey))
        XCTAssertEqual(marker, expectedMarker(key: harness.key))
        XCTAssertNil(try opened.configValue(key: VaultStore.componentMetadataLegacyCompletionKey))
        XCTAssertEqual(try encoder.encode(opened.db.read { try CredentialRecord.fetchAll($0) }), records)
        XCTAssertEqual(try migrationHistory(opened), history)
        try opened.close()
        let repeated = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
        defer { try? repeated.close() }
        XCTAssertNil(repeated.componentMetadataIssue)
        XCTAssertEqual(try repeated.configValue(key: VaultStore.componentMetadataCompletionKey), marker)
    }

    func testTamperedNoncanonicalAndWrongKeyV2MarkersFailWithoutRepair() throws {
        for variant in ["tampered", "noncanonical", "wrong-key"] {
            let harness = try makeHarness { _ in true }
            var bytes = try XCTUnwrap(Data(base64Encoded: expectedMarker(key: harness.key)))
            bytes[0] ^= 1
            let marker = variant == "tampered" ? bytes.base64EncodedString()
                : variant == "noncanonical" ? String(expectedMarker(key: harness.key).dropLast())
                : expectedMarker(key: VaultCrypto.generateKey())
            try harness.store.setConfigValue(key: VaultStore.componentMetadataCompletionKey, value: marker)
            try assertIntegrityOnOpen(harness)
            XCTAssertEqual(try harness.store.configValue(key: VaultStore.componentMetadataCompletionKey), marker)
        }
    }

    func testGeneralKeyCiphertextFromAnotherFieldCannotSatisfyV2() throws {
        let harness = try makeHarness { _ in true }
        let credential = try harness.vault.createTextCredential(
            .init(name: legacyMessage, value: "synthetic"), using: .allow)
        let row = try XCTUnwrap(harness.store.fetchAllCredentials().first { $0.id == credential.id })
        XCTAssertEqual(try VaultCrypto.decrypt(row.encryptedDisplayName, using: harness.key), legacyMessage)
        let substituted = row.encryptedDisplayName.base64EncodedString()
        try harness.store.setConfigValue(key: VaultStore.componentMetadataCompletionKey, value: substituted)
        try assertIntegrityOnOpen(harness)
        XCTAssertEqual(try harness.store.configValue(key: VaultStore.componentMetadataCompletionKey), substituted)
    }

    func testInvalidV1AndMixedVersionsFailWithoutUpgrade() throws {
        for variant in ["corrupt", "wrong-key", "wrong-message", "mixed"] {
            let harness = try makeHarness { _ in true }
            let marker = variant == "corrupt" ? "invalid" : try VaultCrypto.encrypt(
                variant == "wrong-message" ? "synthetic-other-message" : legacyMessage,
                using: variant == "wrong-key" ? VaultCrypto.generateKey() : harness.key).base64EncodedString()
            try harness.store.setConfigValue(key: VaultStore.componentMetadataLegacyCompletionKey, value: marker)
            if variant != "mixed" {
                try harness.store.setConfigValue(key: VaultStore.componentMetadataCompletionKey, value: nil)
            }
            let before = try config(harness.store)
            try assertIntegrityOnOpen(harness)
            XCTAssertEqual(try config(harness.store), before)
        }
    }

    func testV1WithMissingMetadataDoesNotUpgrade() throws {
        let harness = try makeHarness { _ in true }
        _ = try harness.vault.createTextCredential(.init(name: "Synthetic", value: "synthetic"), using: .allow)
        var row = try XCTUnwrap(harness.store.fetchAllCredentials().first)
        row.encryptedComponentMetadata = nil
        try harness.store.updateCredential(row)
        try installV1(in: harness.store, key: harness.key)
        let before = try config(harness.store)
        try assertIntegrityOnOpen(harness)
        XCTAssertEqual(try config(harness.store), before)
    }

    func testInterruptedUpgradeRollsBackBothMarkersAndReopensSuccessfully() throws {
        let harness = try makeHarness { _ in true }
        try installV1(in: harness.store, key: harness.key)
        let before = try config(harness.store)
        let history = try migrationHistory(harness.store)
        try harness.store.db.write { db in
            // Interrupt after v2 insertion, before deleting v1. TEMP objects
            // leave the supported on-disk schema unchanged.
            try db.execute(sql: """
                CREATE TEMP TRIGGER interrupt_marker_upgrade BEFORE DELETE ON config
                WHEN OLD.key = 'component_metadata_completion_v1'
                BEGIN SELECT RAISE(ABORT, 'synthetic interruption'); END
                """)
        }
        try harness.store.prepareComponentMetadata(using: harness.key)
        XCTAssertEqual(harness.store.componentMetadataIssue?.reason, .storage)
        XCTAssertEqual(try config(harness.store), before)
        XCTAssertEqual(try migrationHistory(harness.store), history)
        try harness.store.close()
        let opened = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
        defer { try? opened.close() }
        XCTAssertNil(opened.componentMetadataIssue)
        XCTAssertEqual(try opened.configValue(key: VaultStore.componentMetadataCompletionKey), expectedMarker(key: harness.key))
        XCTAssertNil(try opened.configValue(key: VaultStore.componentMetadataLegacyCompletionKey))
    }

    func testUnkeyedEmptyLibraryAcceptsOnlyOneWellFormedMarkerVersion() throws {
        for mixed in [false, true] {
            let harness = try makeHarness { _ in true }
            let paths = VaultBootstrapPaths(directory: harness.databaseURL.deletingLastPathComponent().appendingPathComponent("bootstrap"))
            let keys = MemoryAppKeyStore()
            let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
            try installV1(in: opened.store, key: opened.key, keepsV2: mixed)
            try opened.store.close()
            keys.appKey = nil
            if mixed {
                let before = try Data(contentsOf: paths.currentDatabase)
                XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
                XCTAssertEqual(try Data(contentsOf: paths.currentDatabase), before)
            } else {
                let recreated = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
                defer { try? recreated.store.close() }
                XCTAssertTrue(recreated.created)
                XCTAssertNil(recreated.store.componentMetadataIssue)
            }
        }
    }

    private func installV1(in store: VaultStore, key: SymmetricKey, keepsV2: Bool = false) throws {
        let marker = try VaultCrypto.encrypt(legacyMessage, using: key).base64EncodedString()
        try store.db.write { db in
            if !keepsV2 { try ConfigRecord.deleteOne(db, key: VaultStore.componentMetadataCompletionKey) }
            try ConfigRecord(key: VaultStore.componentMetadataLegacyCompletionKey, value: marker).insert(db)
        }
    }

    private func expectedMarker(key: SymmetricKey) -> String {
        let markerKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(),
            info: Data("AskKey component metadata completion authentication v2".utf8), outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(
            for: Data("AskKey component metadata complete v2\0".utf8), using: markerKey)).base64EncodedString()
    }

    private func assertIntegrityOnOpen(_ harness: Harness) throws {
        let opened = try VaultStore(path: harness.databaseURL.path, authenticationKey: harness.key)
        defer { try? opened.close() }
        XCTAssertEqual(opened.componentMetadataIssue?.reason, .integrity)
        let vault = Vault(store: opened, key: harness.key)
        XCTAssertFalse(vault.isLocked)
        try vault.beginManagementSession(using: .allow)
        XCTAssertNoThrow(try vault.listTextCredentials())
        XCTAssertThrowsError(try vault.brokerCredentialCatalog()) { XCTAssertEqual($0 as? BrokerProviderError, .agentAccessPaused) }
    }

    private func config(_ store: VaultStore) throws -> [String: String] {
        try store.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM config").map {
                ($0["key"] as String, $0["value"] as String)
            })
        }
    }

    private func migrationHistory(_ store: VaultStore) throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid") }
    }
}
