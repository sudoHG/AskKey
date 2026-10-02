import CryptoKit
import Foundation
import XCTest
@testable import AskKeyCore

final class ICloudBackupBoundaryTests: XCTestCase {
    func testRealFileStoreAcceptsOneTrailingDirectorySeparatorButRejectsTraversal() throws {
        let fixture = try makeFixture()
        let prefix = "askkey-backup/audit-key/generations"
        let path = prefix + "/audit-generation/blob"
        try fixture.cloud.create(Data("SYNTHETIC_CIPHERTEXT".utf8), at: path)
        XCTAssertEqual(try fixture.cloud.list(prefix: prefix), [path])
        XCTAssertEqual(try fixture.cloud.list(prefix: prefix + "/"), [path])
        for invalid in ["", "/", "askkey-backup//", "askkey-backup/../", "askkey-backup/./"] {
            XCTAssertThrowsError(try fixture.cloud.list(prefix: invalid), invalid)
        }
        XCTAssertThrowsError(try fixture.cloud.read(at: path + "/"))
    }

#if DEBUG
    func testExclusivePublicationNeverOverwritesAnObjectCreatedWhileStaging() throws {
        let fixture = try makeFixture()
        let path = "askkey-backup/exclusive/generations/first/blob"
        let winner = Data("OTHER_WRITER_COMPLETE_OBJECT".utf8)
        var publicationHookError: Error?
        fixture.cloud.exclusiveWriteProbe = { stage, _ in
            guard stage == .beforePublication else { return }
            fixture.cloud.exclusiveWriteProbe = nil
            do { try fixture.cloud.create(winner, at: path) }
            catch { publicationHookError = error }
        }
        XCTAssertThrowsError(try fixture.cloud.create(Data("LOSING_WRITER_OBJECT".utf8), at: path)) {
            XCTAssertEqual($0 as? ICloudBackupStoreError, .alreadyExists)
        }
        XCTAssertNil(publicationHookError)
        XCTAssertEqual(try fixture.cloud.read(at: path), winner)
        XCTAssertEqual(try fixture.cloud.list(prefix: "askkey-backup/"), [path])
    }
#endif

    func testCoordinatorRoundTripsAndRetainsTwoGenerationsThroughRealFileStore() throws {
        let fixture = try makeFixture()
        let backup = try makeBackup(fixture.cloud)
        _ = try backup.backUp(snapshot: snapshot("one"))
        let previous = try backup.backUp(snapshot: snapshot("two"))
        let current = try backup.backUp(snapshot: snapshot("three"))

        XCTAssertEqual(try backup.restore(), snapshot("three"))
        let manifests = try fixture.cloud.list(prefix: "askkey-backup/")
            .filter { $0.hasSuffix("/manifest.json") }
        XCTAssertEqual(manifests.count, 2)
        XCTAssertTrue(manifests.contains { $0.contains(previous.id) })
        XCTAssertTrue(manifests.contains { $0.contains(current.id) })
    }

    func testSnapshotIncludesEmptyGroupsAndRestoreReplacesDestinationGroupsAtomically() throws {
        let source = try makeVault()
        let destination = try makeVault()
        try source.vault.createCredentialGroup("Empty Source Group", using: .allow)
        _ = try source.vault.createTextCredential(
            .init(name: "Source Credential", value: "SYNTHETIC", groupName: "Used Group", permission: .allowed),
            using: .allow
        )
        try destination.vault.createCredentialGroup("Old Empty Group", using: .allow)
        _ = try destination.vault.createTextCredential(
            .init(name: "Old Credential", value: "OLD_SYNTHETIC", groupName: "Old Used Group", permission: .ask),
            using: .allow
        )
        let backupSnapshot = try source.vault.makeICloudBackupSnapshot(settings: settings)
        XCTAssertEqual(backupSnapshot.groupNames, ["Empty Source Group", "Used Group"])
        var safetyData: Data?

        try destination.vault.restoreLibraryFromICloudBackup(
            backupSnapshot,
            currentSettings: { self.settings },
            persistLocalSafetySnapshot: { safetyData = $0 },
            applySettings: { _ in }
        )

        XCTAssertEqual(try destination.vault.listCredentialGroups(), backupSnapshot.groupNames)
        XCTAssertEqual(try destination.vault.listTextCredentials().map(\.name), ["Source Credential"])
        let safety = try JSONDecoder().decode(
            ICloudBackupSnapshot.self,
            from: VaultCrypto.decryptData(XCTUnwrap(safetyData), using: destination.key)
        )
        XCTAssertEqual(safety.groupNames, ["Old Empty Group", "Old Used Group"])
        XCTAssertEqual(try destination.vault.listTextCredentials().first?.permission, .ask)
    }

    func testEmptyLibraryRestoreReplacesGroupsAndInvalidGroupsLeaveDestinationUntouched() throws {
        let destination = try makeVault()
        try destination.vault.createCredentialGroup("Old Group", using: .allow)
        let replacement = ICloudBackupSnapshot(credentials: [], groupNames: ["Restored Empty Group"], settings: settings)
        try destination.vault.restoreLibraryFromICloudBackup(
            replacement,
            currentSettings: { self.settings },
            persistLocalSafetySnapshot: { _ in },
            applySettings: { _ in }
        )
        XCTAssertEqual(try destination.vault.listCredentialGroups(), ["Restored Empty Group"])

        let invalid = ICloudBackupSnapshot(credentials: [], groupNames: ["  "], settings: settings)
        XCTAssertThrowsError(try destination.vault.restoreLibraryFromICloudBackup(
            invalid,
            currentSettings: { self.settings },
            persistLocalSafetySnapshot: { _ in XCTFail("Invalid input must not begin replacement") },
            applySettings: { _ in XCTFail("Invalid input must not apply settings") }
        ))
        XCTAssertEqual(try destination.vault.listCredentialGroups(), ["Restored Empty Group"])
    }

    func testPausedVaultCannotReadBackupSnapshotOrPublishCloudGeneration() throws {
        let fixture = try makeFixture()
        let source = try makeVault()
        let backup = try makeBackup(fixture.cloud)
        try source.vault.pauseAgentAccess(using: .allow)

        XCTAssertThrowsError(try source.vault.makeICloudBackupSnapshot(settings: settings)) {
            guard case VaultError.agentAccessPaused = $0 else { return XCTFail("Expected pause, got \($0)") }
        }
        XCTAssertThrowsError(try source.vault.backUpToICloud(using: backup, settings: settings)) {
            guard case VaultError.agentAccessPaused = $0 else { return XCTFail("Expected pause, got \($0)") }
        }
        XCTAssertTrue(try fixture.cloud.list(prefix: "askkey-backup/").isEmpty)
        try source.vault.resumeAgentAccess(using: .allow)
        _ = try source.vault.backUpToICloud(using: backup, settings: settings)
        XCTAssertEqual(try backup.restore().groupNames, [])
    }

    func testPauseWaitsForInFlightCloudCommitAndRejectsNewBackupsWhileWaiting() throws {
        let fixture = try makeFixture()
        let cloud = BlockingBackupCloud(base: fixture.cloud)
        let source = try makeVault()
        let backup = try makeBackup(cloud)
        let backupSettings = settings
        let backupDone = expectation(description: "Admitted backup finishes")
        let pauseDone = expectation(description: "Pause completes after backup")
        let backupResult = BackupBoundaryResult<ICloudBackupGeneration>()
        let pauseResult = BackupBoundaryResult<Void>()
        defer { cloud.release.signal() }
        DispatchQueue.global().async {
            backupResult.store(Result { try source.vault.backUpToICloud(using: backup, settings: backupSettings) })
            backupDone.fulfill()
        }
        XCTAssertEqual(cloud.blocked.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            pauseResult.store(Result { try source.vault.pauseAgentAccess(using: .allow) })
            pauseDone.fulfill()
        }
        // Observe the gate's actual quiescing transition, not a scheduling sleep.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !(try source.vault.isAgentAccessPaused()), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        XCTAssertTrue(try source.vault.isAgentAccessPaused())
        XCTAssertFalse(pauseResult.completed)
        XCTAssertThrowsError(try source.vault.backUpToICloud(using: backup, settings: settings)) {
            guard case VaultError.agentAccessPaused = $0 else { return XCTFail("Expected pause, got \($0)") }
        }

        cloud.release.signal()
        wait(for: [backupDone, pauseDone], timeout: 5)
        _ = try backupResult.value().get()
        try pauseResult.value().get()
        XCTAssertTrue(try source.vault.isAgentAccessPaused())
        XCTAssertEqual(try fixture.cloud.list(prefix: "askkey-backup/").filter { $0.hasSuffix("/manifest.json") }.count, 1)
    }

    func testRestoreSafetySnapshotStillWorksWhenAgentAccessWasAlreadyPaused() throws {
        let target = try makeVault()
        try target.vault.createCredentialGroup("Paused Empty Group", using: .allow)
        try target.vault.pauseAgentAccess(using: .allow)
        var safetyData: Data?
        try target.vault.restoreLibraryFromICloudBackup(
            ICloudBackupSnapshot(credentials: [], groupNames: ["Restored"], settings: settings),
            currentSettings: { self.settings },
            persistLocalSafetySnapshot: { safetyData = $0 },
            applySettings: { _ in }
        )
        XCTAssertTrue(try target.vault.isAgentAccessPaused())
        XCTAssertEqual(try target.vault.listCredentialGroups(), ["Restored"])
        XCTAssertNotNil(safetyData)
    }

    private var settings: ICloudBackupSettings {
        .init(languageMode: "system", appearanceMode: "system", defaultTimedAllowanceMinutes: 30, launchAtLogin: false)
    }

    private func snapshot(_ value: String) -> ICloudBackupSnapshot {
        .init(
            credentials: [.init(id: "synthetic", displayName: "Synthetic", payload: .text(value), permission: .ask)],
            groupNames: ["Empty Group"], settings: settings
        )
    }

    private func makeFixture() throws -> (root: URL, cloud: ICloudFileBackupStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupBoundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try ICloudFileBackupStore(
            provider: BackupBoundaryContainer(root: root),
            fileManager: BackupBoundaryFileManager(root: root)
        ))
    }

    private func makeBackup(_ cloud: ICloudBackupStore) throws -> ICloudBackupCoordinator {
        try ICloudBackupCoordinator(
            store: cloud,
            recoveryKey: BackupRecoveryKey(encoded: Data(repeating: 0x51, count: 32).base64EncodedString()),
            writerID: "11111111-1111-4111-8111-111111111111",
            stateStore: BackupBoundaryState()
        )
    }

    private func makeVault() throws -> (vault: Vault, key: SymmetricKey) {
        let fixture = try makeFixture()
        let store = try VaultStore(path: fixture.root.appendingPathComponent("vault.db").path)
        addTeardownBlock { try? store.close() }
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let vault = Vault(store: store, key: key)
        try vault.beginManagementSession(using: .allow)
        return (vault, key)
    }
}

private struct BackupBoundaryContainer: ICloudBackupContainerProviding {
    let root: URL
    func containerURL() -> URL? { root }
}

private final class BackupBoundaryFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
}

private final class BackupBoundaryState: ICloudBackupLocalStateStore {
    private let lock = NSLock()
    private var paused = false
    private var takeover: String?
    private var cleanup: [String] = []
    private var upload: Data?
    func beginExclusiveAccess(namespace: String) { lock.lock() }
    func endExclusiveAccess(namespace: String) { lock.unlock() }
    func isAutomaticBackupPaused(namespace: String) throws -> Bool { paused }
    func setAutomaticBackupPaused(_ value: Bool, namespace: String) throws { paused = value }
    func acceptedTakeoverGeneration(namespace: String) throws -> String? { takeover }
    func setAcceptedTakeoverGeneration(_ value: String?, namespace: String) throws { takeover = value }
    func pendingCleanupPaths(namespace: String) throws -> [String] { cleanup }
    func setPendingCleanupPaths(_ value: [String], namespace: String) throws { cleanup = value }
    func pendingUpload(namespace: String) throws -> Data? { upload }
    func setPendingUpload(_ value: Data?, namespace: String) throws { upload = value }
    func stopAllAutomaticBackups() { paused = true }
    func resumeAutomaticBackupsForNewInstallation() { paused = false }
}

private final class BackupBoundaryResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    var completed: Bool {
        lock.lock(); defer { lock.unlock() }
        return result != nil
    }
    func store(_ value: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        result = value
    }
    func value() throws -> Result<Value, Error> {
        lock.lock(); defer { lock.unlock() }
        return try XCTUnwrap(result)
    }
}

private final class BlockingBackupCloud: ICloudBackupStore {
    let base: ICloudBackupStore
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    init(base: ICloudBackupStore) { self.base = base }
    func create(_ data: Data, at path: String) throws {
        if path.hasSuffix("/blob") {
            blocked.signal()
            guard release.wait(timeout: .now() + 8) == .success else {
                throw ICloudBackupStoreError.unavailable
            }
        }
        try base.create(data, at: path)
    }
    func replace(_ data: Data, at path: String) throws { try base.replace(data, at: path) }
    func read(at path: String) throws -> Data? { try base.read(at: path) }
    func list(prefix: String) throws -> [String] { try base.list(prefix: prefix) }
    func conflictPaths(prefix: String) throws -> [String] { try base.conflictPaths(prefix: prefix) }
    func resolveConflicts(prefix: String) throws { try base.resolveConflicts(prefix: prefix) }
    func delete(at path: String) throws { try base.delete(at: path) }
}
