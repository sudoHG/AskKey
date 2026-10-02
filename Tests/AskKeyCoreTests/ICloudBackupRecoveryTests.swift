import Darwin
import Foundation
import XCTest
@testable import AskKeyCore

/// Uses a fresh XCTest subprocess and SIGKILL after a real file-store write.
/// Neither Swift catch nor defer runs in that process. All bytes, the cloud
/// container, upload journal, home and temporary paths belong to this fixture.
final class ICloudBackupRecoveryTests: XCTestCase {
    func testAbruptTerminationRecoversOwnedFirstUploadAtEachPublicationBoundary() throws {
        for point in ["/writer.json", "/children/root.json", "/blob", "/manifest.json", "/current.json"] {
            let root = try makeRoot()
            try runAbruptBackup(root: root, point: point)
            let fixture = try makeFixture(root: root)
            let journal = try XCTUnwrap(fixture.state.pendingUpload(namespace: fixture.key.keyID))
            XCTAssertNil(journal.range(of: Data("ORIGINAL_SYNTHETIC_BACKUP_MATERIAL".utf8)))
            XCTAssertNil(journal.range(of: Data(fixture.key.encoded.utf8)))
            let before = try fixture.cloud.list(prefix: "askkey-backup/")
            if point == "/children/root.json" {
                XCTAssertTrue(before.contains { $0.hasSuffix("/children/root.json") })
                XCTAssertFalse(before.contains { $0.hasSuffix("/manifest.json") })
                XCTAssertFalse(before.contains { $0.hasSuffix("/blob") })
            }

            let resumed = try ICloudBackupCoordinator(
                store: fixture.cloud, recoveryKey: fixture.key, writerID: Self.writer,
                stateStore: fixture.state
            )
            _ = try resumed.backUp(snapshot: Self.snapshot("NEW_SYNTHETIC_BACKUP_REQUEST"))
            let expected = point == "/writer.json"
                ? Self.snapshot("NEW_SYNTHETIC_BACKUP_REQUEST")
                : Self.snapshot("ORIGINAL_SYNTHETIC_BACKUP_MATERIAL")
            XCTAssertEqual(try resumed.restore(), expected, point)
            XCTAssertNil(try fixture.state.pendingUpload(namespace: fixture.key.keyID))
            XCTAssertEqual(
                try fixture.cloud.list(prefix: "askkey-backup/").filter { $0.hasSuffix("/manifest.json") }.count,
                1, point
            )

            _ = try resumed.backUp(snapshot: Self.snapshot("AFTER_RECOVERY"))
            XCTAssertEqual(try resumed.restore(), Self.snapshot("AFTER_RECOVERY"))
        }
    }

#if DEBUG
    func testAbruptTerminationInsideExclusiveWriteReplaysAuthenticatedJournal() throws {
        for point in ["inside-partial:/blob", "inside-publish:/blob", "inside-partial:/manifest.json", "inside-publish:/manifest.json"] {
            let root = try makeRoot()
            try runAbruptBackup(root: root, point: point)
            let fixture = try makeFixture(root: root)
            let finalSuffix = String(point.split(separator: ":", maxSplits: 1)[1])
            let paths = try fixture.cloud.list(prefix: "askkey-backup/")
            XCTAssertFalse(paths.contains { $0.hasSuffix(finalSuffix) }, point)
            XCTAssertFalse(paths.contains { $0.contains(".askkey-upload-") }, point)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appendingPathComponent("cloud"), includingPropertiesForKeys: nil))
            let hidden = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasPrefix(".askkey-upload-") }
            XCTAssertEqual(hidden.count, 1, "SIGKILL must occur inside the real exclusive writer: \(point)")
            let temporaryBytes = try Data(contentsOf: XCTUnwrap(hidden.first))
            XCTAssertFalse(temporaryBytes.isEmpty)
            XCTAssertNotNil(try fixture.state.pendingUpload(namespace: fixture.key.keyID))
            let resumed = try ICloudBackupCoordinator(store: fixture.cloud, recoveryKey: fixture.key,
                writerID: Self.writer, stateStore: fixture.state)
            _ = try resumed.backUp(snapshot: Self.snapshot("NEW_REQUEST_MUST_NOT_REPLACE_PENDING"))
            XCTAssertEqual(try resumed.restore(), Self.snapshot("ORIGINAL_SYNTHETIC_BACKUP_MATERIAL"), point)
            XCTAssertNil(try fixture.state.pendingUpload(namespace: fixture.key.keyID))
            let completed = try fixture.cloud.list(prefix: "askkey-backup/")
            let finalPath = try XCTUnwrap(completed.first { $0.hasSuffix(finalSuffix) })
            let finalBytes = try XCTUnwrap(fixture.cloud.read(at: finalPath))
            if point.hasPrefix("inside-partial:") {
                XCTAssertLessThan(temporaryBytes.count, finalBytes.count)
            } else {
                XCTAssertEqual(temporaryBytes, finalBytes)
            }
            XCTAssertEqual(completed.filter { $0.hasSuffix("/manifest.json") }.count, 1)
        }
    }

#endif

    func testUnknownOrTamperedLocalPreparationCannotRepairACloudClaim() throws {
        let root = try makeRoot()
        try runAbruptBackup(root: root, point: "/children/root.json")
        let fixture = try makeFixture(root: root)
        let pathsBefore = try fixture.cloud.list(prefix: "askkey-backup/")
        var journal = try XCTUnwrap(fixture.state.pendingUpload(namespace: fixture.key.keyID))
        let original = journal
        journal[journal.startIndex] ^= 0xff
        try fixture.state.setPendingUpload(journal, namespace: fixture.key.keyID)
        let tampered = try ICloudBackupCoordinator(
            store: fixture.cloud, recoveryKey: fixture.key, writerID: Self.writer, stateStore: fixture.state
        )
        XCTAssertThrowsError(try tampered.backUp(snapshot: Self.snapshot("must-not-upload"))) {
            XCTAssertEqual($0 as? ICloudBackupError, .invalidPendingUpload)
        }
        XCTAssertEqual(try fixture.cloud.list(prefix: "askkey-backup/"), pathsBefore)

        try fixture.state.setPendingUpload(nil, namespace: fixture.key.keyID)
        let unknown = try ICloudBackupCoordinator(
            store: fixture.cloud, recoveryKey: fixture.key, writerID: Self.writer, stateStore: fixture.state
        )
        XCTAssertThrowsError(try unknown.backUp(snapshot: Self.snapshot("still-must-not-upload"))) {
            XCTAssertEqual($0 as? ICloudBackupError, .propagationPending)
        }
        XCTAssertEqual(try fixture.cloud.list(prefix: "askkey-backup/"), pathsBefore)

        // Only restoring the exact authenticated local preparation permits replay.
        try fixture.state.setPendingUpload(original, namespace: fixture.key.keyID)
        _ = try unknown.backUp(snapshot: Self.snapshot("ignored-during-replay"))
        XCTAssertEqual(try unknown.restore(), Self.snapshot("ORIGINAL_SYNTHETIC_BACKUP_MATERIAL"))
    }

    func testPendingJournalFailurePreventsTheFirstCloudWrite() throws {
        let root = try makeRoot()
        let fixture = try makeFixture(root: root)
        fixture.state.rejectSaves = true
        let backup = try ICloudBackupCoordinator(
            store: fixture.cloud, recoveryKey: fixture.key, writerID: Self.writer, stateStore: fixture.state
        )
        XCTAssertThrowsError(try backup.backUp(snapshot: Self.snapshot("blocked")))
        XCTAssertTrue(try fixture.cloud.list(prefix: "askkey-backup/").isEmpty)
    }

    func testAbruptBackupProcess() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["ASKKEY_BACKUP_CRASH_ROOT"],
              let point = environment["ASKKEY_BACKUP_CRASH_POINT"] else {
            throw XCTSkip("Only the isolated abrupt-termination subprocess invokes this entry.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard root.lastPathComponent.hasPrefix("AskKeyBackupCrash-"),
              try Data(contentsOf: root.appendingPathComponent("fixture-marker"))
                == Data("isolated synthetic backup crash test".utf8) else {
            throw ICloudBackupStoreError.unavailable
        }
        let fixture = try makeFixture(root: root)
#if DEBUG
        if point.hasPrefix("inside-") {
            let parts = point.split(separator: ":", maxSplits: 1).map(String.init)
            fixture.cloud.exclusiveWriteProbe = { stage, finalURL in
                guard parts.count == 2, finalURL.path.hasSuffix(parts[1]) else { return }
                let matches = (parts[0] == "inside-partial" && stage == .partialWrite)
                    || (parts[0] == "inside-publish" && stage == .beforePublication)
                guard matches else { return }
                _ = Darwin.kill(getpid(), SIGKILL)
                _exit(99)
            }
        }
#endif
        let cloud = AbruptBackupCloud(base: fixture.cloud, point: point)
        let backup = try ICloudBackupCoordinator(
            store: cloud, recoveryKey: fixture.key, writerID: Self.writer, stateStore: fixture.state
        )
        _ = try backup.backUp(snapshot: Self.snapshot("ORIGINAL_SYNTHETIC_BACKUP_MATERIAL"))
        XCTFail("The configured publication boundary was not reached")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyBackupCrash-\(UUID().uuidString)", isDirectory: true)
        for directory in [root, root.appendingPathComponent("home"), root.appendingPathComponent("staging")] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try Data("isolated synthetic backup crash test".utf8)
            .write(to: root.appendingPathComponent("fixture-marker"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFixture(root: URL) throws -> (
        cloud: ICloudFileBackupStore, state: DurableBackupTestState, key: BackupRecoveryKey
    ) {
        (
            try ICloudFileBackupStore(
                provider: RecoveryTestContainer(root: root.appendingPathComponent("cloud")),
                fileManager: RecoveryTestFileManager(root: root.appendingPathComponent("staging"))
            ),
            DurableBackupTestState(directory: root.appendingPathComponent("pending-uploads")),
            try BackupRecoveryKey(encoded: Data(repeating: 0x61, count: 32).base64EncodedString())
        )
    }

    private func runAbruptBackup(root: URL, point: String) throws {
        let log = root.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest", "AskKeyCoreTests.ICloudBackupRecoveryTests/testAbruptBackupProcess",
            Bundle(for: ICloudBackupRecoveryTests.self).bundleURL.path,
        ]
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": root.appendingPathComponent("home").path,
            "CFFIXED_USER_HOME": root.appendingPathComponent("home").path,
            "TMPDIR": root.appendingPathComponent("staging").path + "/",
            "ASKKEY_BACKUP_CRASH_ROOT": root.path,
            "ASKKEY_BACKUP_CRASH_POINT": point,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            return XCTFail("Isolated backup subprocess exceeded its 15-second limit")
        }
        process.waitUntilExit()
        let diagnostics = String(decoding: try Data(contentsOf: log).prefix(8_192), as: UTF8.self)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, diagnostics)
        XCTAssertEqual(process.terminationStatus, SIGKILL, diagnostics)
    }

    private static var writer: String { "11111111-1111-4111-8111-111111111111" }
    private static func snapshot(_ value: String) -> ICloudBackupSnapshot {
        .init(
            credentials: [.init(id: "synthetic", displayName: "Synthetic", payload: .text(value), permission: .ask)],
            groupNames: ["Empty Synthetic Group"],
            settings: .init(languageMode: "system", appearanceMode: "system", defaultTimedAllowanceMinutes: 30, launchAtLogin: false)
        )
    }
}

private struct RecoveryTestContainer: ICloudBackupContainerProviding {
    let root: URL
    func containerURL() -> URL? { root }
}

private final class RecoveryTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
}

private final class DurableBackupTestState: ICloudBackupLocalStateStore {
    private let lock = NSLock()
    private let journal: FileICloudBackupPendingUploadStore
    private var paused = false
    private var takeover: String?
    private var cleanup: [String] = []
    var rejectSaves = false
    init(directory: URL) { journal = FileICloudBackupPendingUploadStore(directory: directory) }
    func beginExclusiveAccess(namespace: String) { lock.lock() }
    func endExclusiveAccess(namespace: String) { lock.unlock() }
    func isAutomaticBackupPaused(namespace: String) throws -> Bool { paused }
    func setAutomaticBackupPaused(_ value: Bool, namespace: String) throws { paused = value }
    func acceptedTakeoverGeneration(namespace: String) throws -> String? { takeover }
    func setAcceptedTakeoverGeneration(_ value: String?, namespace: String) throws { takeover = value }
    func pendingCleanupPaths(namespace: String) throws -> [String] { cleanup }
    func setPendingCleanupPaths(_ value: [String], namespace: String) throws { cleanup = value }
    func pendingUpload(namespace: String) throws -> Data? { try journal.read(namespace: namespace) }
    func setPendingUpload(_ value: Data?, namespace: String) throws {
        if rejectSaves { throw ICloudBackupStoreError.unavailable }
        try journal.write(value, namespace: namespace)
    }
    func stopAllAutomaticBackups() { paused = true }
    func resumeAutomaticBackupsForNewInstallation() { paused = false }
}

private final class AbruptBackupCloud: ICloudBackupStore {
    let base: ICloudBackupStore
    let point: String
    init(base: ICloudBackupStore, point: String) { self.base = base; self.point = point }
    func create(_ data: Data, at path: String) throws {
        try base.create(data, at: path)
        terminateIfRequested(path)
    }
    func replace(_ data: Data, at path: String) throws {
        try base.replace(data, at: path)
        terminateIfRequested(path)
    }
    func read(at path: String) throws -> Data? { try base.read(at: path) }
    func list(prefix: String) throws -> [String] { try base.list(prefix: prefix) }
    func conflictPaths(prefix: String) throws -> [String] { try base.conflictPaths(prefix: prefix) }
    func resolveConflicts(prefix: String) throws { try base.resolveConflicts(prefix: prefix) }
    func delete(at path: String) throws { try base.delete(at: path) }
    private func terminateIfRequested(_ path: String) {
        guard path.hasSuffix(point) else { return }
        _ = Darwin.kill(getpid(), SIGKILL)
        _exit(99)
    }
}
