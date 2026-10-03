import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
@testable import AskKeyVault

final class CurrentLibraryOpeningRaceTests: XCTestCase {
    func testDisappearingValidatedDatabaseIsNotRecreated() throws {
        let (paths, keys) = try fixtureLibrary()
        var before: [String: Data]?
        try SyntheticOpeningVFS.withHook(for: paths.currentDatabase, mutation: {
            try FileManager.default.moveItem(at: paths.currentDatabase,
                                            to: paths.directory.appendingPathComponent("retained-original.db"))
            before = try directoryBytes(paths.directory)
        }) {
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        }
        XCTAssertEqual(try directoryBytes(paths.directory), try XCTUnwrap(before))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testReplacedValidatedDatabaseIsRejectedWithoutChangingItsFiles() throws {
        let (paths, keys) = try fixtureLibrary()
        var before: [String: Data]?
        try SyntheticOpeningVFS.withHook(for: paths.currentDatabase, mutation: {
            try FileManager.default.moveItem(at: paths.currentDatabase,
                                            to: paths.directory.appendingPathComponent("retained-original.db"))
            try FileManager.default.copyItem(at: self.fixture("library.db"), to: paths.currentDatabase)
            let replacement = try DatabaseQueue(path: paths.currentDatabase.path)
            try replacement.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('unknown-replacement')") }
            try replacement.close()
            before = try directoryBytes(paths.directory)
        }) {
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        }
        XCTAssertEqual(try directoryBytes(paths.directory), try XCTUnwrap(before))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testByteIdenticalReplacementIsRejectedWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        var before: [String: Data]?
        try SyntheticOpeningVFS.withHook(for: paths.currentDatabase, mutation: {
            try FileManager.default.moveItem(at: paths.currentDatabase,
                                            to: paths.directory.appendingPathComponent("retained-original.db"))
            try FileManager.default.copyItem(at: self.fixture("library.db"), to: paths.currentDatabase)
            before = try directoryBytes(paths.directory)
        }) {
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        }
        XCTAssertEqual(try directoryBytes(paths.directory), try XCTUnwrap(before))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testSymlinkReplacementIsRejectedWithoutChangingTargetOrSidecars() throws {
        let (paths, keys) = try fixtureLibrary()
        var before: [String: Data]?
        try SyntheticOpeningVFS.withHook(for: paths.currentDatabase, mutation: {
            try FileManager.default.moveItem(at: paths.currentDatabase,
                                            to: paths.directory.appendingPathComponent("retained-original.db"))
            try FileManager.default.copyItem(at: self.fixture("library.db"),
                                            to: paths.directory.appendingPathComponent("replacement.db"))
            try FileManager.default.createSymbolicLink(atPath: paths.currentDatabase.path,
                                                      withDestinationPath: "replacement.db")
            before = try directoryBytes(paths.directory)
        }) {
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        }
        XCTAssertEqual(try directoryBytes(paths.directory), try XCTUnwrap(before))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: paths.currentDatabase.path),
                       "replacement.db")
        XCTAssertEqual(keys.mutations, 0)
    }

    func testExistingLibraryPathEscapesURIQueryCharacters() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory().appendingPathComponent("library ?&#% 中文"))
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: fixture("library.db"), to: paths.currentDatabase)
        let keys = MemoryAppKeyStore(appKey: try Data(contentsOf: fixture("library.key")))
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        try opened.store.close()
        XCTAssertEqual(keys.mutations, 1, "only the best-effort deletePendingKey")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.directory.path), ["credentials-v2.db"])
    }

    func testWALCommitAfterPreflightIsRejectedWithoutChangingAnyFile() throws {
        let (paths, keys) = try fixtureLibrary()
        let writer = try DatabaseQueue(path: paths.currentDatabase.path)
        defer { try? writer.close() }
        var before: [String: Data]?
        try SyntheticOpeningVFS.withHook(for: paths.currentDatabase, mutation: {
            try writer.write { try $0.execute(sql: "INSERT INTO grdb_migrations VALUES ('unknown-after-preflight')") }
            before = try directoryBytes(paths.directory)
        }) {
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
        }
        XCTAssertEqual(try directoryBytes(paths.directory), try XCTUnwrap(before))
        XCTAssertEqual(keys.mutations, 0)
    }

    func testFreshBootstrapRejectsOrphanedCurrentSidecarsWithoutChangingFilesOrKeys() throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
            let keys = MemoryAppKeyStore()
            try Data("SYNTHETIC-orphan\(suffix)".utf8)
                .write(to: URL(fileURLWithPath: paths.currentDatabase.path + suffix))
            let before = try directoryBytes(paths.directory)
            XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys), suffix)
            XCTAssertEqual(try directoryBytes(paths.directory), before, suffix)
            XCTAssertEqual(keys.mutations, 0, suffix)
        }
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyOpeningRace-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
}

/// A test-only SQLite VFS seam, firing after all private-copy preflights and
/// immediately before the real main database is opened. It never hooks Sources.
private final class SyntheticOpeningVFS {
    private static let lock = NSLock()
    private static var active: SyntheticOpeningVFS?
    private let original: UnsafeMutablePointer<sqlite3_vfs>
    private let hooked: UnsafeMutablePointer<sqlite3_vfs>
    private let name: UnsafeMutablePointer<CChar>
    private let target: String
    private let mutation: () throws -> Void
    private var fired = false
    private var mutationError: Error?
    private var openedMainFiles: [String] = []

    private init(target: URL, mutation: @escaping () throws -> Void) throws {
        original = try XCTUnwrap(sqlite3_vfs_find(nil))
        hooked = .allocate(capacity: 1)
        hooked.initialize(to: original.pointee)
        name = try XCTUnwrap(strdup("AskKeySyntheticOpening-\(UUID().uuidString)"))
        self.target = target.resolvingSymlinksInPath().path
        self.mutation = mutation
        hooked.pointee.zName = UnsafePointer(name)
        hooked.pointee.pNext = nil
        hooked.pointee.xOpen = { _, filename, file, flags, outputFlags in
            guard let context = SyntheticOpeningVFS.active else { return SQLITE_MISUSE }
            if flags & SQLITE_OPEN_MAIN_DB != 0, let filename {
                context.openedMainFiles.append(String(cString: filename))
            }
            if !context.fired, flags & SQLITE_OPEN_MAIN_DB != 0,
               let filename,
               URL(fileURLWithPath: String(cString: filename)).resolvingSymlinksInPath().path == context.target {
                context.fired = true
                do { try context.mutation() }
                catch { context.mutationError = error; return SQLITE_IOERR }
            }
            return context.original.pointee.xOpen!(context.original, filename, file, flags, outputFlags)
        }
    }

    static func withHook(
        for target: URL, mutation: @escaping () throws -> Void, operation: () throws -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        let context = try SyntheticOpeningVFS(target: target, mutation: mutation)
        active = context
        defer {
            _ = sqlite3_vfs_register(context.original, 1)
            _ = sqlite3_vfs_unregister(context.hooked)
            active = nil
            context.hooked.deinitialize(count: 1)
            context.hooked.deallocate()
            free(context.name)
        }
        XCTAssertEqual(sqlite3_vfs_register(context.hooked, 1), SQLITE_OK)
        try operation()
        if let error = context.mutationError { throw error }
        XCTAssertTrue(context.fired, "The actual current-file opening seam must be exercised: \(context.target), \(context.openedMainFiles)")
    }
}
