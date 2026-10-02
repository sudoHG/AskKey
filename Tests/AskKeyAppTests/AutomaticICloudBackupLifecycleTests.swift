import CryptoKit
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

@MainActor
final class AutomaticICloudBackupLifecycleTests: XCTestCase {
    func testClosingManagementSessionDoesNotDisableAutomaticBackup() {
        var enabled = true
        var disableCalls = 0
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            iCloudBackupEnabled: { enabled },
            setICloudBackupEnabled: { value in
                if !value { disableCalls += 1 }
                enabled = value
                return value
            },
            preferences: AppPreferences(
                defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
            ),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.isLocked = false
        model.hasManagementSession = true
        model.iCloudBackupEnabled = true

        model.endManagementSession()
        model.refreshICloudBackupEnabled()

        XCTAssertFalse(model.hasManagementSession)
        XCTAssertTrue(model.iCloudBackupEnabled)
        XCTAssertEqual(disableCalls, 0)
    }

    func testDevelopmentCapabilityFailureIsHonestAndDoesNotRequireManagementSession() {
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            iCloudBackupEnabled: { throw ICloudBackupError.capabilityUnavailable },
            preferences: AppPreferences(
                defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard
            ),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.hasManagementSession = false
        model.languageMode = "en"
        model.refreshICloudBackupEnabled()

        XCTAssertFalse(model.hasManagementSession)
        XCTAssertFalse(model.iCloudBackupEnabled)
        XCTAssertEqual(
            model.iCloudBackupStatusMessage,
            "This development or ad-hoc build does not have Ask Key's own iCloud capability. Official releases require Ask Key's container, entitlement, and signing materials."
        )
        XCTAssertTrue(
            model.iCloudBackupStatusMessage?.contains("Official releases") == true
        )
    }

    func testImmediateBackupStillRequiresAManagementSession() {
        var backupCalls = 0
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            immediateICloudBackup: {
                backupCalls += 1
                return ICloudBackupGeneration(id: "unused", createdAt: Date())
            },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        model.hasManagementSession = false
        XCTAssertNil(model.backUpNow())
        XCTAssertEqual(backupCalls, 0)
    }

    func testControllerCapabilityDecisionDoesNotClaimFixtureSigning() {
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { throw ICloudBackupError.capabilityUnavailable },
            inspectCapability: {
                ICloudBackupCapabilityInspection.decide(
                    ICloudBackupCapabilityRequest(
                        bundleIdentifier: "com.sudohg.askkey.app",
                        infoPlistContainerIdentifier: "iCloud.com.sudohg.askkey.fixture",
                        entitlementContainerIdentifiers: ["iCloud.com.sudohg.askkey.fixture"],
                        signing: .init(
                            teamIdentifier: "ABCDEFGHIJ",
                            identityKind: .developerID,
                            codesignEntitlementContainers: ["iCloud.com.sudohg.askkey.fixture"],
                            isFixture: true
                        )
                    )
                )
            }
        )
        XCTAssertEqual(controller.capabilityDecision(), .fixtureUnproven)
    }

    func testSecondStartKeepsTheSameSchedulerAndRebindsSettingsObserver() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let vault = try makeSyntheticVault()
        let clock = ManualLifecycleClock()
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { throw ICloudBackupError.capabilityUnavailable },
            dirtyDefaults: defaults,
            dirtyKey: "icloudAutomaticBackupDirty.test"
        )
        var firstBackups = 0
        var secondBackups = 0
        controller.startAutomaticScheduling(
            vault: vault,
            schedule: clock.schedule,
            operations: .init(
                backup: {
                    firstBackups += 1
                    return ICloudBackupGeneration(id: "first", createdAt: Date())
                },
                isEnabled: { true },
                hasPendingUpload: { false }
            )
        )
        let firstScheduler = try XCTUnwrap(controller.installedScheduler)
        controller.startAutomaticScheduling(
            vault: vault,
            schedule: clock.schedule,
            operations: .init(
                backup: {
                    secondBackups += 1
                    return ICloudBackupGeneration(id: "second", createdAt: Date())
                },
                isEnabled: { true },
                hasPendingUpload: { false }
            )
        )
        XCTAssertTrue(controller.installedScheduler === firstScheduler)
        NotificationCenter.default.post(name: .askKeyOrdinaryBackupSettingsDidChange, object: nil)
        XCTAssertEqual(clock.pendingCount, 1)
        clock.fireAll()
        XCTAssertEqual(firstBackups, 0)
        XCTAssertEqual(secondBackups, 1)
    }

    func testRestartDuringInFlightBackupDoesNotLetRetiredWriteOverwriteLedger() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let dirtyKey = "icloudAutomaticBackupDirty.inflight"
        let vault = try makeSyntheticVault()
        let clock = ManualLifecycleClock()
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { throw ICloudBackupError.capabilityUnavailable },
            dirtyDefaults: defaults,
            dirtyKey: dirtyKey
        )
        let started = DispatchSemaphore(value: 0)
        let hold = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        var backups = 0
        let operations = AutomaticBackupOperations(
            backup: {
                started.signal()
                hold.wait()
                backups += 1
                finished.signal()
                return ICloudBackupGeneration(id: "in-flight", createdAt: Date())
            },
            isEnabled: { true },
            hasPendingUpload: { false }
        )
        controller.startAutomaticScheduling(vault: vault, schedule: clock.schedule, operations: operations)
        let firstScheduler = try XCTUnwrap(controller.installedScheduler)
        firstScheduler.noteSuccessfulChange()
        let worker = DispatchQueue(label: "askkey.lifecycle.inflight-restart")
        worker.async { clock.fireAll() }
        XCTAssertEqual(started.wait(timeout: .now() + 3), .success)
        controller.startAutomaticScheduling(vault: vault, schedule: clock.schedule, operations: operations)
        XCTAssertTrue(controller.installedScheduler === firstScheduler)
        try XCTUnwrap(controller.installedScheduler).noteSuccessfulChange()
        hold.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        worker.sync {}
        let change = defaults.integer(forKey: dirtyKey + ".change")
        let confirmed = defaults.integer(forKey: dirtyKey + ".confirmed")
        XCTAssertEqual(change, 2)
        XCTAssertEqual(confirmed, 1)
        XCTAssertGreaterThan(change, confirmed)
        XCTAssertEqual(backups, 1)
    }

    func testBrokerRetryStartUsesInjectedVaultInsteadOfShared() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let vault = try makeSyntheticVault()
        _ = try vault.createTextCredential(
            .init(name: "Injected", value: "NOT-SHARED", permission: .ask),
            using: .allow
        )
        var backedUpNames: [String] = []
        let clock = ManualLifecycleClock()
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { throw ICloudBackupError.capabilityUnavailable },
            dirtyDefaults: defaults,
            dirtyKey: "icloudAutomaticBackupDirty.retry"
        )
        let operations = AutomaticBackupOperations(
            backup: {
                backedUpNames = try vault.listTextCredentials().map(\.name)
                return ICloudBackupGeneration(id: "injected", createdAt: Date())
            },
            isEnabled: { true },
            hasPendingUpload: { false }
        )
        controller.startAutomaticScheduling(vault: vault, schedule: clock.schedule, operations: operations)
        controller.startAutomaticScheduling(vault: vault, schedule: clock.schedule, operations: operations)
        vault.notifySnapshotRelevantChange()
        clock.fireAll()
        XCTAssertEqual(backedUpNames, ["Injected"])
        XCTAssertTrue(Vault.shared !== vault)
    }
}

private func makeSyntheticVault() throws -> Vault {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AskKeyLifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try VaultStore(path: root.appendingPathComponent("vault.db").path)
    let vault = Vault(store: store, key: SymmetricKey(data: Data(repeating: 0x24, count: 32)))
    try vault.beginManagementSession(using: .allow)
    return vault
}

private final class ManualLifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [() -> Void] = []

    func schedule(delay: TimeInterval, work: @escaping () -> Void) -> AutomaticICloudBackupScheduler.Cancellation {
        lock.lock()
        var alive = true
        self.work.append {
            if alive { work() }
        }
        lock.unlock()
        return .init { alive = false }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return work.count
    }

    func fireAll() {
        lock.lock()
        let jobs = work
        work = []
        lock.unlock()
        jobs.forEach { $0() }
    }
}
