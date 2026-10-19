import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class VaultBootstrapKeyOriginTests: XCTestCase {
    private let planted = Data(repeating: 0xA7, count: 32)

    func testFreshCreationDeletesUnreadablePendingItemBeforeSavingItsOwnKey() throws {
        let paths = try paths()
        let keys = MemoryAppKeyStore()
        keys.pendingKey = planted
        keys.pendingLoadFailure = SyntheticCrash()
        keys.onPendingDelete = { keys.pendingLoadFailure = nil }
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertTrue(opened.created)
        XCTAssertNotEqual(VaultCrypto.keyToData(opened.key), planted)
        XCTAssertEqual(keys.appKey, VaultCrypto.keyToData(opened.key))
        XCTAssertNil(keys.pendingKey)
        try opened.store.close()
    }

    func testMalformedPendingKeyWithUnfinishedDatabaseIsDiscarded() throws {
        let paths = try paths()
        let keys = MemoryAppKeyStore()
        try leaveUnfinished(paths, keys: keys)
        keys.pendingKey = Data(repeating: 7, count: 33)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertTrue(opened.created)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key).count, 32)
        try opened.store.close()
        XCTAssertNotNil(keys.appKey)
        XCTAssertNil(keys.pendingKey)
    }

    func testPendingDeletionConflictPreservesFreshAndUnfinishedFilesAndKeys() throws {
        for current in [false, true] {
            let paths = try paths()
            let keys = MemoryAppKeyStore()
            if current { try leaveUnfinished(paths, keys: keys) }
            keys.pendingKey = planted
            keys.pendingDeleteFailure = AppKeyStoreError.conflictingItem(.pendingKey)
            let before = try directoryBytes(paths.directory)
            keys.mutations = 0
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
                XCTAssertEqual($0 as? AppKeyStoreError, .conflictingItem(.pendingKey))
                XCTAssertEqual(($0 as? AppKeyStoreError)?.errorDescription,
                               AppKeychainItemKind.pendingKey.conflictMessage)
            }
            XCTAssertEqual(try directoryBytes(paths.directory), before)
            XCTAssertNil(keys.appKey)
            XCTAssertEqual(keys.pendingKey, planted)
            XCTAssertEqual(keys.mutations, 0)
            XCTAssertEqual(keys.policyWrites, 0)
        }
    }

    func testRecreatedLibraryAndDefaultPolicyUseOnlyNewlyGeneratedKey() throws {
        try assertRecreatedLibraryAndDefaultPolicy(hasPending: true)
    }

    func testUnfinishedLibraryWithoutEitherKeyIsRecreatedAndWritesDefaultPolicyOnce() throws {
        try assertRecreatedLibraryAndDefaultPolicy(hasPending: false)
    }

    private func assertRecreatedLibraryAndDefaultPolicy(hasPending: Bool) throws {
        let paths = try paths()
        let keys = MemoryAppKeyStore()
        try leaveUnfinished(paths, keys: keys)
        let before = try directoryBytes(paths.directory)
        let previous = try XCTUnwrap(keys.pendingKey)
        keys.pendingKey = hasPending ? planted : nil
        keys.onPendingSave = { data in
            XCTAssertNotEqual(data, self.planted)
            XCTAssertNotEqual(data, previous)
            XCTAssertNotEqual(try Data(contentsOf: paths.currentDatabase), before["credentials-v2.db"])
            XCTAssertNil(keys.appKey)
            XCTAssertEqual(keys.policyWrites, 0)
        }
        keys.onPolicyLoad = {
            XCTAssertNotNil(keys.appKey)
            XCTAssertNotEqual(keys.appKey, self.planted)
            XCTAssertNil(keys.pendingKey)
        }
        let vault = Vault(paths: paths, keyStore: keys,
                          fileDeliveryManager: try FileDeliveryManager(rootURL: paths.directory.appendingPathComponent("deliveries")))
        defer { try? vault.store.close() }
        try vault.unlock()
        let generated = try XCTUnwrap(keys.appKey)
        let policy = try XCTUnwrap(keys.policy)
        XCTAssertEqual(keys.policyWrites, 1)
        XCTAssertEqual(try AgentAccessPolicyAuthentication.open(policy, using: VaultCrypto.keyFromData(generated)), .defaults)
        XCTAssertThrowsError(try AgentAccessPolicyAuthentication.open(policy, using: VaultCrypto.keyFromData(planted)))
        _ = try vault.createTextCredential(.init(name: "SYNTHETIC-TOKEN", value: "synthetic", permission: .allowed), using: .deny)
        let record = try XCTUnwrap(vault.store.fetchAllCredentials().first)
        XCTAssertThrowsError(try CredentialRecordAuthentication.verify(record, using: VaultCrypto.keyFromData(planted)))
        try CredentialRecordAuthentication.verify(record, using: VaultCrypto.keyFromData(generated))
        try vault.unlock()
        XCTAssertEqual(keys.appKey, generated)
        XCTAssertEqual(keys.policyWrites, 1, "ordinary reopen must not sign defaults again")
    }

    func testNonmatchingLibraryWithoutAppKeyPreservesAllFilesAndNeverWritesPolicy() throws {
        for hasPending in [false, true] {
            let paths = try paths()
            let keys = MemoryAppKeyStore()
            try leaveUnfinished(paths, keys: keys)
            let store = try VaultStore(path: paths.currentDatabase.path)
            try store.setConfigValue(key: "SYNTHETIC-user-setting", value: "preserve")
            try store.close()
            keys.pendingKey = hasPending ? planted : nil
            keys.mutations = 0
            let vault = Vault(paths: paths, keyStore: keys,
                              fileDeliveryManager: try FileDeliveryManager(rootURL: paths.directory.appendingPathComponent("deliveries")))
            let before = try directoryBytes(paths.directory)
            XCTAssertThrowsError(try vault.unlock()) {
                XCTAssertEqual($0 as? VaultBootstrapError, .missingKey)
            }
            XCTAssertEqual(try directoryBytes(paths.directory), before)
            XCTAssertEqual(keys.pendingKey, hasPending ? planted : nil)
            XCTAssertNil(keys.appKey)
            XCTAssertEqual(keys.mutations, 0)
            XCTAssertEqual(keys.policyWrites, 0)
        }
    }

    func testRecreationRemovesCurrentWALSidecarsAndPreservesHistoricalSiblings() throws {
        let paths = try paths()
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.prepareDatabase { db in
            var persistWAL: CInt = 1
            XCTAssertEqual(sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, &persistWAL), SQLITE_OK)
        }
        let database = try DatabaseQueue(path: paths.currentDatabase.path, configuration: configuration)
        try CurrentLibrarySchema.migrator().migrate(database)
        try database.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.currentDatabase.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.currentDatabase.path + "-shm"))
        let siblings = ["vault.db", "migration-v2.journal", "credentials-v2.db.pending",
                        "credentials-v2.db.pending-wal", "credentials-v2.db.pending-shm"]
        for name in siblings {
            try Data("SYNTHETIC-\(name)".utf8).write(to: paths.directory.appendingPathComponent(name))
        }
        let before = try directoryBytes(paths.directory)
        let keys = MemoryAppKeyStore()
        keys.pendingKey = planted
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertTrue(opened.created)
        XCTAssertNotEqual(VaultCrypto.keyToData(opened.key), planted)
        try opened.store.close()
        let after = try directoryBytes(paths.directory)
        XCTAssertEqual(Set(after.keys), Set(siblings + ["credentials-v2.db"]))
        for name in siblings { XCTAssertEqual(after[name], before[name], name) }
        XCTAssertNil(keys.pendingKey)
    }

    func testInterruptionAtEveryCreationStepReopensWithOneRunGeneratedKey() throws {
        for recreating in [false, true] {
            for point in CrashPoint.allCases {
                let paths = try paths()
                let keys = MemoryAppKeyStore()
                if recreating { try leaveUnfinished(paths, keys: keys) }
                keys.pendingKey = planted
                var saved: [Data] = []
                var synchronized: [String] = []
                keys.onPendingSave = { data in
                    XCTAssertNil(keys.appKey)
                    XCTAssertNotEqual(data, self.planted)
                    XCTAssertEqual(synchronized, [paths.creatingDatabase, paths.currentDatabase,
                                                  paths.directory, paths.durabilityRoot].map(\.path))
                    saved.append(data)
                    if point == .pendingSaved { throw SyntheticCrash() }
                }
                keys.onPromotion = { if point == .promoted { throw SyntheticCrash() } }
                keys.onPendingDelete = {
                    if point == .pendingDiscarded && keys.appKey == nil { throw SyntheticCrash() }
                    if point == .pendingDeleted && keys.appKey != nil { throw SyntheticCrash() }
                }
                if point == .beforePromotion { keys.promotionFailure = SyntheticCrash() }
                XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys,
                    beforeCreationRename: { _ in if point == .beforeRename { throw SyntheticCrash() } },
                    synchronize: { target in
                        try VaultBootstrap.synchronize(target)
                        synchronized.append(target.url.path)
                        let failureURL: URL?
                        switch point {
                        case .creatingSynced: failureURL = paths.creatingDatabase
                        case .databaseSynced: failureURL = paths.currentDatabase
                        case .directorySynced: failureURL = paths.directory
                        case .rootSynced: failureURL = paths.durabilityRoot
                        default: failureURL = nil
                        }
                        if target.url.path == failureURL?.path { throw SyntheticCrash() }
                    }
                ), "\(point), recreating: \(recreating)") { XCTAssertTrue($0 is SyntheticCrash) }
                let promoted = keys.appKey
                let previous = saved.last
                keys.onPendingSave = { saved.append($0) }
                keys.onPendingDelete = nil
                keys.onPromotion = nil
                keys.promotionFailure = nil
                let reopened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
                let final = VaultCrypto.keyToData(reopened.key)
                XCTAssertNotEqual(final, planted)
                XCTAssertEqual(final, saved.last)
                XCTAssertEqual(keys.appKey, final)
                XCTAssertNil(keys.pendingKey)
                if let promoted {
                    XCTAssertFalse(reopened.created)
                    XCTAssertEqual(final, promoted, "a promoted App key remains authoritative")
                } else {
                    XCTAssertTrue(reopened.created)
                    if let previous { XCTAssertNotEqual(final, previous, "never resume a previous run's pending value") }
                }
                try reopened.store.close()
            }
        }
    }

    func testPendingValueChangedAfterSaveIsRejectedBeforePromotion() throws {
        let paths = try paths()
        let keys = MemoryAppKeyStore()
        keys.onPendingSave = { _ in keys.pendingKey = self.planted }
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? AppKeyStoreError, .conflictingKey)
        }
        XCTAssertNil(keys.appKey)
        keys.onPendingSave = nil
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertNotEqual(VaultCrypto.keyToData(opened.key), planted)
        XCTAssertNil(keys.pendingKey)
        try opened.store.close()
    }

    private enum CrashPoint: CaseIterable {
        case pendingDiscarded, beforeRename, creatingSynced, databaseSynced, directorySynced, rootSynced
        case pendingSaved, beforePromotion, promoted, pendingDeleted
    }

    private struct SyntheticCrash: Error {}

    private func paths() throws -> VaultBootstrapPaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyKeyOrigin-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return VaultBootstrapPaths(directory: directory, durabilityRoot: root)
    }

    private func leaveUnfinished(_ paths: VaultBootstrapPaths, keys: MemoryAppKeyStore) throws {
        keys.promotionFailure = SyntheticCrash()
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertTrue($0 is SyntheticCrash)
        }
        keys.promotionFailure = nil
        XCTAssertNil(keys.appKey)
        XCTAssertNotNil(keys.pendingKey)
        XCTAssertEqual(keys.policyWrites, 0)
    }
}
