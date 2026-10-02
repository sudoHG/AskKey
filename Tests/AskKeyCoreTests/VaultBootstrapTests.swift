import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class VaultBootstrapTests: XCTestCase {
    func testAgentStartupCreatesFreshLibraryWithoutManagementSession() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        let placeholder = try VaultStore(path: try temporaryDirectory().appendingPathComponent("placeholder.db").path)
        let vault = Vault(store: placeholder)
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        let historical = paths.directory.appendingPathComponent("restore-safety/opaque")
        try FileManager.default.createDirectory(at: historical.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SYNTHETIC_HISTORY".utf8).write(to: historical)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertEqual(try Data(contentsOf: historical), Data("SYNTHETIC_HISTORY".utf8))
        defer { try? vault.store.close() }
        XCTAssertFalse(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertNotNil(keys.appKey)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(try vault.brokerCredentialCatalog(cancellation: .init()).count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.appendingPathComponent("vault.db").path))
    }

    func testAgentStartupLoadsCurrentLibraryWithoutManagementSessionAndIsIdempotent() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore()
        let initial = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        let vault = Vault(store: initial.store, key: initial.key)
        _ = try vault.createTextCredential(.init(name: "TOKEN", value: "synthetic", environmentVariable: "TOKEN", permission: .allowed), using: .deny)
        vault.lock()
        XCTAssertTrue(vault.isLocked)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertFalse(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertThrowsError(try vault.listTextCredentials())
        XCTAssertEqual(try vault.brokerCredentialCatalog(cancellation: .init()).count, 1)
        vault.approvalRequests.setReadAuthenticationEnabled(false)
        vault.approvalRequests.configureAuthentication { _ in false }
        try vault.prepareAgentRuntime(paths: paths, keyStore: {
            XCTFail("Already loaded runtime must not read keys again")
            return keys
        })
        XCTAssertFalse(vault.hasActiveManagementSession)
        let ticket = try vault.approvalRequests.submit(.init(
            operationID: "startup-read", credentialID: "TOKEN", targetID: "TOKEN",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none)
        XCTAssertEqual(try vault.approvalRequests.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once
        ).state, .approved)
        try vault.beginManagementSession(using: .allow)
        try vault.pauseAgentAccess(using: .allow)
        try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })
        XCTAssertTrue(try vault.isAgentAccessPaused())
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        vault.lock()
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        try vault.store.close()
    }

    func testFreshBootstrapResumesInterruptedCreationWithPendingKey() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let pending = Data(repeating: 0x42, count: 32)
        let keys = MemoryAppKeyStore()
        keys.pendingKey = pending
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), pending)
        XCTAssertEqual(try opened.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM grdb_migrations") }, 2)
        try opened.store.close()
        XCTAssertEqual(keys.appKey, pending)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(keys.mutations, 2, "only promotion and deletion; no new pending key")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.directory.path), ["credentials-v2.db"])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: paths.currentDatabase.path)[.posixPermissions] as? Int,
                       0o600)
        XCTAssertEqual(try VaultBootstrap.state(paths: paths), .current)

        let before = try directoryBytes(paths.directory)
        let reopened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(reopened.key), pending)
        try reopened.store.close()
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.appKey, pending)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(keys.mutations, 3, "the App-key reopen only calls deletePendingKey")
    }

    func testFailureBeforeCreationRenameLeavesNoCurrentDatabaseAndNextLaunchReusesPendingKey() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        try writePendingSiblings(paths)
        let siblings = try directoryBytes(paths.directory)
        let keys = MemoryAppKeyStore()
        var observedCreation = false
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeCreationRename: { creating in
            observedCreation = true
            XCTAssertEqual(creating, paths.creatingDatabase)
            XCTAssertTrue(FileManager.default.fileExists(atPath: creating.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.currentDatabase.path))
            throw InjectedCreationFailure()
        })) { XCTAssertTrue($0 is InjectedCreationFailure) }
        XCTAssertTrue(observedCreation)
        XCTAssertEqual(try directoryBytes(paths.directory), siblings, "no current or creation file remains")
        XCTAssertNil(keys.appKey)
        let pending = try XCTUnwrap(keys.pendingKey)
        XCTAssertEqual(pending.count, 32)
        XCTAssertEqual(try VaultBootstrap.state(paths: paths), .fresh)

        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), pending)
        XCTAssertEqual(try opened.store.db.read {
            try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }, CurrentLibrarySchema.currentIdentifiers)
        XCTAssertFalse(try opened.store.db.read { try $0.tableExists("projects") })
        try opened.store.close()
        XCTAssertEqual(keys.appKey, pending)
        XCTAssertNil(keys.pendingKey)
        let after = try directoryBytes(paths.directory)
        XCTAssertEqual(Set(after.keys), Set(siblings.keys).union(["credentials-v2.db"]))
        for (name, bytes) in siblings { XCTAssertEqual(after[name], bytes, name) }
    }

    func testCurrentDatabaseAppearingBeforeCreationRenameIsNeverReplaced() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        try writePendingSiblings(paths)
        let siblings = try directoryBytes(paths.directory)
        let marker = Data("SYNTHETIC-current-marker".utf8)
        let keys = MemoryAppKeyStore()
        var observedCreation = false
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeCreationRename: { _ in
            observedCreation = true
            try marker.write(to: paths.currentDatabase)
        })) { XCTAssertEqual($0 as? VaultBootstrapError, .invalidState) }
        XCTAssertTrue(observedCreation)
        XCTAssertEqual(try Data(contentsOf: paths.currentDatabase), marker)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.creatingDatabase.path + suffix), suffix)
        }
        let after = try directoryBytes(paths.directory)
        XCTAssertEqual(Set(after.keys), Set(siblings.keys).union(["credentials-v2.db"]))
        for (name, bytes) in siblings { XCTAssertEqual(after[name], bytes, name) }
        XCTAssertEqual(keys.pendingKey?.count, 32)
        XCTAssertNil(keys.appKey)
        XCTAssertEqual(keys.mutations, 1, "only savePendingKey")
    }

    func testCreationSynchronizesLibraryAndEntryChainBeforePromotion() throws {
        let root = try temporaryDirectory()
        let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-a/SYNTHETIC-b"))
        let keys = MemoryAppKeyStore()
        var synchronized: [URL] = []
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeDurabilitySync: { url in
            XCTAssertNil(keys.appKey, "synchronized before promotion")
            synchronized.append(url)
        })
        try opened.store.close()
        XCTAssertEqual(synchronized.map(\.standardizedFileURL.path), [
            paths.currentDatabase, paths.directory, paths.directory.deletingLastPathComponent(), root,
        ].map(\.standardizedFileURL.path), "both created levels and their parents")
        XCTAssertNotNil(keys.appKey)

        synchronized = []
        let existing = VaultBootstrapPaths(directory: try temporaryDirectory())
        let reopened = try VaultBootstrap.openCurrent(paths: existing, keyStore: MemoryAppKeyStore(),
                                                      beforeDurabilitySync: { synchronized.append($0) })
        try reopened.store.close()
        XCTAssertEqual(synchronized.map(\.standardizedFileURL.path), [
            existing.currentDatabase, existing.directory, existing.directory.deletingLastPathComponent(),
        ].map(\.standardizedFileURL.path), "the parent is synchronized even when the directory existed")
    }

    func testCreationSyncFailureKeepsLibraryAndPendingKeyAndNextLaunchRecovers() throws {
        for failing in ["database", "directory", "parent"] {
            let root = try temporaryDirectory()
            let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-data"))
            let target = ["database": paths.currentDatabase, "directory": paths.directory, "parent": root][failing]!
            let keys = MemoryAppKeyStore()
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeDurabilitySync: {
                if $0.standardizedFileURL.path == target.standardizedFileURL.path { throw InjectedCreationFailure() }
            }), failing) { XCTAssertTrue($0 is InjectedCreationFailure, failing) }
            XCTAssertNil(keys.appKey, failing)
            let pending = try XCTUnwrap(keys.pendingKey, failing)
            XCTAssertEqual(keys.mutations, 1, "only savePendingKey: \(failing)")
            XCTAssertEqual(try VaultBootstrap.state(paths: paths), .current, failing)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.directory.path),
                           ["credentials-v2.db"], failing)
            try assertRecoversWithPendingKey(paths: paths, keys: keys, pending: pending)
        }
    }

    func testRecoverySyncFailureKeepsLibraryAndPendingKeyAndNextLaunchRecovers() throws {
        for failing in ["database", "directory", "parent"] {
            let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
            let keys = MemoryAppKeyStore()
            keys.promotionFailure = InjectedCreationFailure()
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
            keys.promotionFailure = nil
            keys.mutations = 0
            let pending = try XCTUnwrap(keys.pendingKey)
            let before = try directoryBytes(paths.directory)
            let target = ["database": paths.currentDatabase, "directory": paths.directory,
                          "parent": paths.directory.deletingLastPathComponent()][failing]!
            var synchronized: [String] = []
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeDurabilitySync: {
                synchronized.append($0.standardizedFileURL.path)
                if $0.standardizedFileURL.path == target.standardizedFileURL.path { throw InjectedCreationFailure() }
            }), failing) { XCTAssertTrue($0 is InjectedCreationFailure, failing) }
            XCTAssertEqual(synchronized.last, target.standardizedFileURL.path, failing)
            XCTAssertNil(keys.appKey, failing)
            XCTAssertEqual(keys.pendingKey, pending, failing)
            XCTAssertEqual(keys.mutations, 0, failing)
            XCTAssertEqual(try directoryBytes(paths.directory), before, failing)
            try assertRecoversWithPendingKey(paths: paths, keys: keys, pending: pending)
        }
    }

    func testCreationRemovesOnlyLeftoverCreationFiles() throws {
        for pending in [nil, Data(repeating: 0x42, count: 32)] {
            let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
            try writePendingSiblings(paths)
            let siblings = try directoryBytes(paths.directory)
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try Data("SYNTHETIC-leftover\(suffix)".utf8)
                    .write(to: URL(fileURLWithPath: paths.creatingDatabase.path + suffix))
            }
            let keys = MemoryAppKeyStore()

            // A fail-closed state leaves even creation leftovers untouched.
            keys.pendingKey = Data(repeating: 0x42, count: 31)
            let rejected = try directoryBytes(paths.directory)
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
                XCTAssertEqual($0 as? VaultBootstrapError, .invalidKey)
            }
            XCTAssertEqual(try directoryBytes(paths.directory), rejected)

            keys.pendingKey = pending
            let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
            if let pending { XCTAssertEqual(VaultCrypto.keyToData(opened.key), pending) }
            try opened.store.close()
            XCTAssertEqual(keys.appKey?.count, 32)
            XCTAssertNil(keys.pendingKey)
            let after = try directoryBytes(paths.directory)
            XCTAssertEqual(Set(after.keys), Set(siblings.keys).union(["credentials-v2.db"]))
            for (name, bytes) in siblings { XCTAssertEqual(after[name], bytes, name) }
        }
    }

    func testCreationTightensDirectoryAndDatabasePermissions() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.directory.path)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: MemoryAppKeyStore())
        try opened.store.close()
        XCTAssertEqual(try permissions(paths.directory), 0o700)
        XCTAssertEqual(try permissions(paths.currentDatabase), 0o600)
    }

    func testFreshBootstrapRejectsMalformedPendingKeyWithoutChangingFilesOrKeys() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        try Data("SYNTHETIC-sibling".utf8).write(to: paths.directory.appendingPathComponent("vault.db"))
        let keys = MemoryAppKeyStore()
        keys.pendingKey = Data(repeating: 0x42, count: 31)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidKey)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.pendingKey, Data(repeating: 0x42, count: 31))
        XCTAssertNil(keys.appKey)
        XCTAssertEqual(keys.mutations, 0)
    }

    func testFreshBootstrapRejectsPendingKeyWithOrphanedCurrentSidecars() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
            try Data("SYNTHETIC-orphan\(suffix)".utf8)
                .write(to: URL(fileURLWithPath: paths.currentDatabase.path + suffix))
            let keys = MemoryAppKeyStore()
            keys.pendingKey = Data(repeating: 0x42, count: 32)
            let before = try directoryBytes(paths.directory)
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys), suffix) {
                XCTAssertEqual($0 as? VaultBootstrapError, .invalidState, suffix)
            }
            XCTAssertEqual(try directoryBytes(paths.directory), before, suffix)
            XCTAssertEqual(keys.pendingKey, Data(repeating: 0x42, count: 32), suffix)
            XCTAssertNil(keys.appKey, suffix)
            XCTAssertEqual(keys.mutations, 0, suffix)
        }
    }

    func testActivatedKeyWithoutDatabaseIgnoresPendingKeyAndChangesNothing() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore(appKey: Data(repeating: 0x42, count: 32))
        keys.pendingKey = Data(repeating: 0x24, count: 32)
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingDatabase)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.appKey, Data(repeating: 0x42, count: 32))
        XCTAssertEqual(keys.pendingKey, Data(repeating: 0x24, count: 32))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testActivatedKeyWithoutDatabaseIsNeverReplaced() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = MemoryAppKeyStore(appKey: Data(repeating: 0x42, count: 32))
        let before = try directoryBytes(paths.directory)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingDatabase)
        }
        XCTAssertEqual(try directoryBytes(paths.directory), before)
        XCTAssertEqual(keys.appKey, Data(repeating: 0x42, count: 32))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testQuiescedCurrentStoreAllowsReadsButRejectsEveryWrite() throws {
        let store = try VaultStore(path: try temporaryDirectory().appendingPathComponent("library.db").path)
        defer { try? store.close() }
        let quiesced = try store.quiescedCopy()
        defer { try? quiesced.close() }
        XCTAssertEqual(try quiesced.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM config") }, 1)
        XCTAssertThrowsError(try quiesced.setConfigValue(key: "must_not_write", value: "blocked"))
    }

    func testClosingCurrentStoreDrainsInFlightWriteAndRejectsFutureWrites() throws {
        let store = try VaultStore(path: try temporaryDirectory().appendingPathComponent("library.db").path)
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "AskKeyStoreDrainTest", attributes: .concurrent)
        worker.async {
            defer { writeFinished.signal() }
            do {
                try store.db.write { database in
                    writeStarted.signal()
                    releaseWrite.wait()
                    try database.execute(sql: "INSERT INTO config (key, value) VALUES ('drained', 'yes')")
                }
            } catch { XCTFail("in-flight write failed: \(error)") }
        }
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        worker.async {
            do { try store.close() } catch { XCTFail("close failed: \(error)") }
            closeFinished.signal()
        }
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.1), .timedOut)
        releaseWrite.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(try store.setConfigValue(key: "after_close", value: "blocked"))
    }

    private struct InjectedCreationFailure: Error {}

    /// The next launch takes rule 6: it promotes `pending` for the library.
    private func assertRecoversWithPendingKey(
        paths: VaultBootstrapPaths, keys: MemoryAppKeyStore, pending: Data
    ) throws {
        keys.mutations = 0
        var synchronized: [String] = []
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeCreationRename: { _ in
            XCTFail("recovery must not create a new library")
        }, beforeDurabilitySync: { synchronized.append($0.standardizedFileURL.path) })
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), pending)
        XCTAssertEqual(try opened.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM projects") }, 1)
        try opened.store.close()
        XCTAssertEqual(synchronized, [paths.currentDatabase, paths.directory,
                                      paths.directory.deletingLastPathComponent()].map(\.standardizedFileURL.path))
        XCTAssertEqual(keys.appKey, pending)
        XCTAssertNil(keys.pendingKey)
        XCTAssertEqual(keys.mutations, 2, "only promotion and deletion")
    }

    private func writePendingSiblings(_ paths: VaultBootstrapPaths) throws {
        try Data("SYNTHETIC-pending-shm".utf8)
            .write(to: paths.directory.appendingPathComponent("credentials-v2.db.pending-shm"))
        try Data("SYNTHETIC-pending-wal".utf8)
            .write(to: paths.directory.appendingPathComponent("credentials-v2.db.pending-wal"))
        try Data("SYNTHETIC-sibling".utf8).write(to: paths.directory.appendingPathComponent("vault.db"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyBootstrap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class MemoryAppKeyStore: AppKeyStore {
    var appKey: Data?
    var pendingKey: Data?
    var mutations = 0
    /// Simulates an interruption between database creation and promotion.
    var promotionFailure: Error?
    /// Simulates a pending key that exists but cannot be read.
    var pendingLoadFailure: Error?
    init(appKey: Data? = nil) { self.appKey = appKey }
    func loadAppKey() throws -> Data {
        guard let appKey else { throw AppKeyStoreError.missingAppKey }
        return appKey
    }
    func loadPendingKey() throws -> Data {
        if let pendingLoadFailure { throw pendingLoadFailure }
        guard let pendingKey else { throw AppKeyStoreError.missingPendingKey }
        return pendingKey
    }
    func savePendingKey(_ data: Data) throws { mutations += 1; pendingKey = data }
    func promotePendingKey() throws {
        if let promotionFailure { throw promotionFailure }
        mutations += 1
        appKey = try loadPendingKey()
    }
    func deletePendingKey() throws { mutations += 1; pendingKey = nil }
    func deleteAppKey() throws { mutations += 1; appKey = nil }
    func deleteLegacyKey() throws { mutations += 1 }
}

func directoryBytes(_ directory: URL) throws -> [String: Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    var result: [String: Data] = [:]
    for name in names {
        let url = directory.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            for (child, bytes) in try directoryBytes(url) { result[name + "/" + child] = bytes }
        } else { result[name] = try Data(contentsOf: url) }
    }
    return result
}

func permissions(_ url: URL) throws -> Int? {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
}
