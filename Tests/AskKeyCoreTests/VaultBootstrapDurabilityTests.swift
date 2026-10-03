import Foundation
import XCTest
@testable import AskKeyCore

final class VaultBootstrapDurabilityTests: XCTestCase {
    func testSymlinkedApplicationSupportAllowsCreationAndRecovery() throws {
        for recovering in [false, true] {
            let root = try temporaryDirectory()
            let support = root.appendingPathComponent("Application Support")
            let destination = root.appendingPathComponent("SYNTHETIC-support")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: support, withDestinationURL: destination)
            let paths = VaultBootstrapPaths(directory: support.appendingPathComponent("AskKey/dev"),
                                            durabilityRoot: support)
            let keys = MemoryAppKeyStore()
            if recovering {
                keys.promotionFailure = SyncInterruption()
                XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
                keys.promotionFailure = nil
            }
            let pending = keys.pendingKey
            var synchronized: [URL] = []
            let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, synchronize: {
                XCTAssertNil(keys.appKey)
                try VaultBootstrap.synchronize($0)
                synchronized.append($0.url)
            })
            try opened.store.close()
            let expected = (recovering ? [] : [paths.creatingDatabase]) + [
                paths.currentDatabase, paths.directory, support.appendingPathComponent("AskKey"), support,
            ]
            XCTAssertEqual(synchronized.map(\.standardizedFileURL.path), expected.map(\.standardizedFileURL.path))
            XCTAssertNotNil(keys.appKey)
            if let pending { XCTAssertEqual(keys.appKey, pending) }
            XCTAssertNil(keys.pendingKey)
        }
    }

    func testInterruptedMultiLevelCreationResynchronizesEveryLevelOnFreshRetryAndRecovery() throws {
        for beforeRename in [false, true] {
            let root = try temporaryDirectory()
            let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-run/nested/core"),
                                            durabilityRoot: root)
            let keys = MemoryAppKeyStore()
            if !beforeRename { keys.promotionFailure = SyncInterruption() }
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, beforeCreationRename: { _ in
                if beforeRename { throw SyncInterruption() }
            })) { XCTAssertTrue($0 is SyncInterruption) }
            keys.promotionFailure = nil
            let pending = try XCTUnwrap(keys.pendingKey)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.directory.path))
            XCTAssertEqual(try VaultBootstrap.state(paths: paths), beforeRename ? .fresh : .current)
            var synchronized: [URL] = []
            let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, synchronize: {
                XCTAssertNil(keys.appKey)
                try VaultBootstrap.synchronize($0)
                synchronized.append($0.url)
            })
            try opened.store.close()
            let expected = (beforeRename ? [paths.creatingDatabase] : []) + [
                paths.currentDatabase, paths.directory, root.appendingPathComponent("SYNTHETIC-run/nested"),
                root.appendingPathComponent("SYNTHETIC-run"), root,
            ]
            XCTAssertEqual(synchronized.map(\.standardizedFileURL.path), expected.map(\.standardizedFileURL.path))
            XCTAssertEqual(keys.appKey, pending)
            XCTAssertNil(keys.pendingKey)
        }
    }

    func testFailureAtEveryDirectoryLevelStopsCreationAndRecoveryBeforePromotion() throws {
        for recovering in [false, true] {
            for level in ["SYNTHETIC-run/nested/core", "SYNTHETIC-run/nested", "SYNTHETIC-run", ""] {
                let root = try temporaryDirectory()
                let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-run/nested/core"),
                                                durabilityRoot: root)
                let keys = MemoryAppKeyStore()
                if recovering {
                    keys.promotionFailure = SyncInterruption()
                    XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
                    keys.promotionFailure = nil
                }
                let target = level.isEmpty ? root : root.appendingPathComponent(level)
                var attempted: [String] = []
                XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, synchronize: {
                    attempted.append($0.url.standardizedFileURL.path)
                    try VaultBootstrap.synchronize($0)
                    if $0.url.standardizedFileURL.path == target.standardizedFileURL.path { throw SyncInterruption() }
                })) { XCTAssertTrue($0 is SyncInterruption) }
                XCTAssertEqual(attempted.last, target.standardizedFileURL.path)
                XCTAssertNil(keys.appKey)
                XCTAssertNotNil(keys.pendingKey)
                XCTAssertEqual(try VaultBootstrap.state(paths: paths), .current)
                let pending = keys.pendingKey
                let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
                try opened.store.close()
                XCTAssertEqual(keys.appKey, pending)
                XCTAssertNil(keys.pendingKey)
            }
        }
    }

    func testRealSyncFailurePropagatesAndLeavesPendingKeyForRecovery() throws {
        let root = try temporaryDirectory()
        let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-data"), durabilityRoot: root)
        let keys = MemoryAppKeyStore()
        for _ in 0..<2 {
            var failedAtRoot = false
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys, synchronize: {
                if $0.url.standardizedFileURL.path == root.standardizedFileURL.path {
                    failedAtRoot = true
                    try VaultBootstrap.synchronize(.directory(root.appendingPathComponent("SYNTHETIC-missing")))
                } else {
                    try VaultBootstrap.synchronize($0)
                }
            })) { XCTAssertEqual($0 as? VaultBootstrapError, .invalidState) }
            XCTAssertTrue(failedAtRoot)
            XCTAssertNil(keys.appKey)
            XCTAssertNotNil(keys.pendingKey)
            XCTAssertEqual(try VaultBootstrap.state(paths: paths), .current)
        }
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try opened.store.close()
        XCTAssertNotNil(keys.appKey)
        XCTAssertNil(keys.pendingKey)
    }

    func testFileSyncRejectsSymlinkAndDirectorySyncRejectsRegularFile() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("SYNTHETIC-file")
        let link = root.appendingPathComponent("credentials-v2.db")
        try Data("SYNTHETIC".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try VaultBootstrap.synchronize(.file(link))) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidState)
        }
        XCTAssertThrowsError(try VaultBootstrap.synchronize(.directory(file))) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidState)
        }
    }

    func testUnrelatedDurabilityRootIsRejectedBeforeMutatingFilesOrKeys() throws {
        let root = try temporaryDirectory()
        let paths = VaultBootstrapPaths(directory: root.appendingPathComponent("SYNTHETIC-data"),
                                        durabilityRoot: root.appendingPathComponent("SYNTHETIC-other"))
        let keys = MemoryAppKeyStore()
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .invalidState)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertEqual(keys.mutations, 0)
    }

    private struct SyncInterruption: Error {}

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyDurability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
}
