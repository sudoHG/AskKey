import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

/// Opt-in native-UI fixtures. Never runs during ordinary regression tests.
final class NativeBootstrapFixtureGenerationTests: XCTestCase {
    func testGenerateSyntheticNativeBootstrapFixtures() throws {
        let basePath = "/private/tmp/askkey-goal-bootstrap-20260906"
        guard ProcessInfo.processInfo.environment["ASKKEY_GENERATE_NATIVE_BOOTSTRAP_FIXTURES"] == basePath else {
            throw XCTSkip("Explicit synthetic fixture generation only")
        }
        let base = URL(fileURLWithPath: basePath, isDirectory: true)
        let manager = FileManager.default
        // Never overwrite a fixture being inspected by a running App.
        guard !manager.fileExists(atPath: base.path) else {
            throw FixtureError.destinationAlreadyExists
        }
        try manager.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = try XCTUnwrap(Bundle.module.url(forResource: "legacy-v7-vault", withExtension: "db", subdirectory: "Fixtures"))
        let legacyKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        for name in ["legacy", "mixed", "migrated"] {
            let root = base.appendingPathComponent(name, isDirectory: true)
            let core = root.appendingPathComponent("core", isDirectory: true)
            try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: core, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let paths = VaultBootstrapPaths(directory: core)
            try manager.copyItem(at: source, to: paths.legacyDatabase)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.legacyDatabase.path)

            if name == "mixed" {
                let store = try VaultStore(path: paths.legacyDatabase.path)
                let vault = Vault(store: store, key: legacyKey,
                    fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries")))
                try vault.beginManagementSession(using: .allow)
                _ = try vault.createTextCredential(.init(name: "合成混合凭证", value: "synthetic-mixed-only", environmentVariable: "SYNTHETIC_MIXED", permission: .allowed), using: .allow)
                let recycled = try vault.createTextCredential(.init(name: "合成回收凭证", value: "synthetic-recycled-only", permission: .hidden), using: .allow)
                try vault.deleteTextCredential(id: recycled.id, using: .allow)
                try vault.createCredentialGroup("合成空分组", using: .allow)
                // Reproduce the historical v13 schema, with real old tables
                // and new credential rows but no authenticated-record column.
                try store.db.write { db in
                    try db.execute(sql: "ALTER TABLE credentials DROP COLUMN authentication_tag")
                    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v14-authenticated-credentials'")
                }
                try store.close()
            }

            if name == "migrated" {
                let keys = FixtureKeyStore(legacy: VaultCrypto.keyToData(legacyKey))
                let committer = MigrationCommitter(legacyDatabaseURL: paths.legacyDatabase, newDatabaseURL: paths.currentDatabase, journalURL: paths.currentJournal, keyStore: keys)
                _ = try committer.prepare()
                try committer.commit()
                XCTAssertEqual(try committer.state(), .complete)
                XCTAssertNil(keys.legacy)
                try writeKey(try keys.loadAppKey(), service: "com.sudohg.askkey.vault.v2.app.dev", root: root)
            } else {
                try writeKey(VaultCrypto.keyToData(legacyKey), service: "com.sudohg.askkey.vault.dev", root: root)
                let preview = try MigrationPlanner(databaseURL: paths.legacyDatabase, legacyKey: legacyKey, migrationKey: VaultCrypto.generateKey()).preview()
                XCTAssertTrue(preview.canCommit)
                XCTAssertEqual(preview.proposals.count, name == "mixed" ? 3 : 1)
            }
            XCTAssertEqual(try VaultBootstrap.state(paths: paths).rawValue, name)
        }
    }

    private func writeKey(_ key: Data, service: String, root: URL) throws {
        let directory = root.appendingPathComponent("key-material", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let namespacedService = service + ".run." + DebugRunDirectory.namespace(for: root)
        let filename = SHA256.hash(data: Data(namespacedService.utf8)).map { String(format: "%02x", $0) }.joined() + ".key"
        let destination = directory.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: destination.path, contents: key, attributes: [.posixPermissions: 0o600]) else {
            throw FixtureError.keyWriteFailed
        }
    }

    private enum FixtureError: Error { case destinationAlreadyExists, keyWriteFailed }
}

private final class FixtureKeyStore: MigrationKeyStore {
    var legacy: Data?
    var pending: Data?
    var app: Data?
    init(legacy: Data) { self.legacy = legacy }
    func loadLegacyKey() throws -> Data { guard let legacy else { throw MigrationKeyStoreError.missingLegacyKey }; return legacy }
    func loadPendingKey() throws -> Data { guard let pending else { throw MigrationKeyStoreError.missingPendingKey }; return pending }
    func loadAppKey() throws -> Data { guard let app else { throw MigrationKeyStoreError.missingAppKey }; return app }
    func savePendingKey(_ data: Data) throws { pending = data }
    func promotePendingKey() throws { app = try loadPendingKey() }
    func deleteLegacyKey() throws { legacy = nil }
    func deletePendingKey() throws { pending = nil }
    func deleteAppKey() throws { app = nil }
}
