import CryptoKit
import Foundation
import XCTest
@testable import AskKeyCore

final class AutomaticICloudBackupSchedulerTests: XCTestCase {
    func testSuccessfulCredentialChangeCreatesRestorableGeneration() throws {
        let fixture = try makeFixture()
        _ = try fixture.vault.createTextCredential(
            .init(name: "Alpha", value: "SYNTHETIC-ALPHA", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()

        let generation = try XCTUnwrap(fixture.scheduler.lastGeneration)
        XCTAssertFalse(generation.id.isEmpty)
        let restored = try fixture.coordinator.restore()
        XCTAssertEqual(restored.credentials.map(\.displayName), ["Alpha"])
        XCTAssertEqual(restored.credentials.first?.payload, .text("SYNTHETIC-ALPHA"))
        XCTAssertTrue(restored.settings.languageMode == "system")
    }

    func testBurstChangesMergeIntoOneBackup() throws {
        let fixture = try makeFixture()
        var backupCount = 0
        fixture.scheduler.replaceBackup {
            backupCount += 1
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        _ = try fixture.vault.createTextCredential(
            .init(name: "One", value: "1", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        _ = try fixture.vault.createTextCredential(
            .init(name: "Two", value: "2", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        try fixture.vault.createCredentialGroup("Merged Group", using: .allow)
        fixture.scheduler.noteSuccessfulChange()
        XCTAssertEqual(backupCount, 0)
        fixture.clock.fireAll()
        XCTAssertEqual(backupCount, 1)
        XCTAssertEqual(try fixture.coordinator.restore().credentials.map(\.displayName).sorted(), ["One", "Two"])
        XCTAssertTrue(try fixture.coordinator.restore().groupNames.contains("Merged Group"))
    }

    func testRestartCompensationUsesPersistedDirtyFlag() throws {
        let ledger = SchedulerChangeLedger()
        let first = try makeFixture(ledger: ledger)
        _ = try first.vault.createTextCredential(
            .init(name: "Pending", value: "BEFORE-RESTART", permission: .ask),
            using: .allow
        )
        first.scheduler.noteSuccessfulChange()
        XCTAssertTrue(ledger.hasUnconfirmedChange)
        XCTAssertNil(first.scheduler.lastGeneration)

        let restarted = try makeFixture(
            vault: first.vault,
            coordinator: first.coordinator,
            ledger: ledger
        )
        restarted.scheduler.compensateOnLaunch()
        restarted.clock.fireAll()
        XCTAssertEqual(try restarted.coordinator.restore().credentials.map(\.displayName), ["Pending"])
        XCTAssertFalse(ledger.hasUnconfirmedChange)
    }

    func testCrashBeforeUploadIntentKeepsUnconfirmedChange() throws {
        let ledger = SchedulerChangeLedger()
        let fixture = try makeFixture(ledger: ledger)
        _ = try fixture.vault.createTextCredential(
            .init(name: "Lost", value: "MUST-SURVIVE-RESTART", permission: .ask),
            using: .allow
        )
        var restartScheduled = 0
        fixture.scheduler.replaceBackup {
            XCTAssertTrue(
                ledger.hasUnconfirmedChange,
                "unconfirmed change must remain until a snapshot covering it is confirmed"
            )
            let restarted = AutomaticICloudBackupScheduler(
                backup: { ICloudBackupGeneration(id: "unused", createdAt: Date()) },
                isEnabled: { true },
                hasPendingUpload: { false },
                loadLedger: { ledger.snapshot },
                persistLedger: { ledger.snapshot = $0 },
                schedule: { _, _ in
                    restartScheduled += 1
                    return .init(cancel: {})
                }
            )
            restarted.compensateOnLaunch()
            XCTAssertGreaterThan(restartScheduled, 0)
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertFalse(ledger.hasUnconfirmedChange)
        XCTAssertEqual(try fixture.coordinator.restore().credentials.map(\.displayName), ["Lost"])
    }

    func testChangeDuringWriteIsNotConfirmedByTheEarlierSnapshot() throws {
        let ledger = SchedulerChangeLedger()
        let fixture = try makeFixture(ledger: ledger)
        var backupCount = 0
        fixture.scheduler.replaceBackup {
            backupCount += 1
            if backupCount == 1 {
                _ = try fixture.vault.createTextCredential(
                    .init(name: "During", value: "AFTER-START", permission: .ask),
                    using: .allow
                )
                fixture.scheduler.noteSuccessfulChange()
            }
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        _ = try fixture.vault.createTextCredential(
            .init(name: "Before", value: "FIRST", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertEqual(backupCount, 1)
        XCTAssertTrue(ledger.hasUnconfirmedChange)
        fixture.clock.fireAll()
        XCTAssertEqual(backupCount, 2)
        XCTAssertFalse(ledger.hasUnconfirmedChange)
        XCTAssertEqual(
            try fixture.coordinator.restore().credentials.map(\.displayName).sorted(),
            ["Before", "During"]
        )
    }

    func testPendingUploadCompletionStillNeedsNewSnapshot() throws {
        let ledger = SchedulerChangeLedger()
        let fixture = try makeFixture(ledger: ledger)
        try fixture.state.setPendingUpload(Data("old-intent".utf8), namespace: fixture.material.recoveryKey.keyID)
        var backupCount = 0
        var sawPending = false
        fixture.scheduler.replaceBackup {
            backupCount += 1
            if try fixture.state.pendingUpload(namespace: fixture.material.recoveryKey.keyID) != nil {
                sawPending = true
                try fixture.state.setPendingUpload(nil, namespace: fixture.material.recoveryKey.keyID)
                return ICloudBackupGeneration(id: "pending-only", createdAt: Date())
            }
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        _ = try fixture.vault.createTextCredential(
            .init(name: "AfterPending", value: "NEW-SNAPSHOT", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertTrue(sawPending)
        XCTAssertEqual(backupCount, 1)
        XCTAssertTrue(ledger.hasUnconfirmedChange)
        fixture.clock.fireAll()
        XCTAssertEqual(backupCount, 2)
        XCTAssertFalse(ledger.hasUnconfirmedChange)
        XCTAssertEqual(try fixture.coordinator.restore().credentials.map(\.displayName), ["AfterPending"])
    }

    func testConfirmDoesNotOverwriteConcurrentSuccessfulChange() throws {
        let dataLock = NSLock()
        var ledger = AutomaticBackupChangeLedger()
        var callback: (() -> Void)?
        let confirming = DispatchSemaphore(value: 0)
        let allowConfirm = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let noted = DispatchSemaphore(value: 0)
        var shouldPauseConfirm = true
        let scheduler = AutomaticICloudBackupScheduler(
            backup: { ICloudBackupGeneration(id: "snapshot-version-1", createdAt: Date()) },
            isEnabled: { true },
            hasPendingUpload: { false },
            loadLedger: {
                dataLock.lock()
                defer { dataLock.unlock() }
                return ledger
            },
            persistLedger: { value in
                let pause: Bool = {
                    dataLock.lock()
                    defer { dataLock.unlock() }
                    guard value.changeVersion == 1, value.confirmedVersion == 1, shouldPauseConfirm else {
                        return false
                    }
                    shouldPauseConfirm = false
                    return true
                }()
                if pause {
                    confirming.signal()
                    XCTAssertEqual(allowConfirm.wait(timeout: .now() + 3), .success)
                }
                dataLock.lock()
                ledger = value
                dataLock.unlock()
            },
            schedule: { _, work in
                callback = work
                return .init(cancel: {})
            }
        )
        scheduler.noteSuccessfulChange()
        let first = try XCTUnwrap(callback)
        DispatchQueue.global(qos: .userInitiated).async {
            first()
            finished.signal()
        }
        XCTAssertEqual(confirming.wait(timeout: .now() + 3), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            scheduler.noteSuccessfulChange()
            noted.signal()
        }
        allowConfirm.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(noted.wait(timeout: .now() + 3), .success)
        dataLock.lock()
        let result = ledger
        dataLock.unlock()
        XCTAssertEqual(result.changeVersion, 2)
        XCTAssertEqual(result.confirmedVersion, 1)
        XCTAssertTrue(result.hasUnconfirmedChange)
    }

    func testClearDirtyDoesNotOverwriteConcurrentSuccessfulChange() {
        let dataLock = NSLock()
        var ledger = AutomaticBackupChangeLedger()
        let clearing = DispatchSemaphore(value: 0)
        let allowClear = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        let noted = DispatchSemaphore(value: 0)
        let scheduler = AutomaticICloudBackupScheduler(
            backup: { ICloudBackupGeneration(id: "unused", createdAt: Date()) },
            isEnabled: { true },
            hasPendingUpload: { false },
            loadLedger: {
                dataLock.lock()
                defer { dataLock.unlock() }
                return ledger
            },
            persistLedger: { value in
                if value.changeVersion == 1 && value.confirmedVersion == 1 {
                    clearing.signal()
                    XCTAssertEqual(allowClear.wait(timeout: .now() + 3), .success)
                }
                dataLock.lock()
                ledger = value
                dataLock.unlock()
            },
            schedule: { _, _ in .init(cancel: {}) }
        )
        scheduler.noteSuccessfulChange()
        DispatchQueue.global(qos: .userInitiated).async {
            scheduler.cancelPendingWork(clearDirty: true)
            cleared.signal()
        }
        XCTAssertEqual(clearing.wait(timeout: .now() + 3), .success)
        DispatchQueue.global(qos: .userInitiated).async {
            scheduler.noteSuccessfulChange()
            noted.signal()
        }
        allowClear.signal()
        XCTAssertEqual(cleared.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(noted.wait(timeout: .now() + 3), .success)
        dataLock.lock()
        let result = ledger
        dataLock.unlock()
        XCTAssertGreaterThan(result.changeVersion, result.confirmedVersion)
        XCTAssertTrue(result.hasUnconfirmedChange)
    }

    func testStopAndResumeDuringWriteKeepsSingleInFlightBackup() throws {
        let fixture = try makeFixture()
        var inFlight = 0
        var peak = 0
        let hold = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        fixture.scheduler.replaceBackup {
            inFlight += 1
            peak = max(peak, inFlight)
            started.signal()
            hold.wait()
            defer {
                inFlight -= 1
                finished.signal()
            }
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        fixture.scheduler.noteSuccessfulChange()
        let worker = DispatchQueue(label: "askkey.backup.stop-resume")
        worker.async { fixture.clock.fireAll() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        fixture.scheduler.cancelPendingWork(clearDirty: false)
        fixture.scheduler.resumeScheduling()
        fixture.clock.fireAll()
        hold.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(peak, 1)
        XCTAssertEqual(inFlight, 0)
    }

    func testFailureRetriesUntilCancelled() throws {
        let fixture = try makeFixture()
        var attempts = 0
        fixture.scheduler.replaceBackup {
            attempts += 1
            if attempts < 3 {
                throw ICloudBackupError.propagationPending
            }
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertEqual(attempts, 1)
        fixture.clock.fireAll()
        XCTAssertEqual(attempts, 2)
        fixture.clock.fireAll()
        XCTAssertEqual(attempts, 3)
        XCTAssertNotNil(fixture.scheduler.lastGeneration)

        attempts = 0
        fixture.scheduler.replaceBackup {
            attempts += 1
            throw ICloudBackupError.propagationPending
        }
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        fixture.scheduler.cancelPendingWork(clearDirty: false)
        fixture.clock.fireAll()
        XCTAssertEqual(attempts, 1)
    }

    func testPauseEraseAndConflictBlockWrites() throws {
        let fixture = try makeFixture()
        _ = try fixture.vault.createTextCredential(
            .init(name: "Blocked", value: "NO-UPLOAD", permission: .ask),
            using: .allow
        )
        try fixture.vault.pauseAgentAccess(using: .allow)
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertNil(fixture.scheduler.lastGeneration)
        XCTAssertTrue(try fixture.cloud.list(prefix: "askkey-backup/").isEmpty)

        try fixture.vault.resumeAgentAccess(using: .allow)
        fixture.state.stopAllAutomaticBackups()
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertNil(fixture.scheduler.lastGeneration)

        fixture.state.resumeAutomaticBackupsForNewInstallation()
        try fixture.cloud.create(
            Data("conflict".utf8),
            at: "askkey-backup/\(fixture.material.recoveryKey.keyID)/generations/conflict/blob (conflicted copy)"
        )
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        XCTAssertEqual(fixture.scheduler.lastError as? ICloudBackupError, .conflictCopy)
        XCTAssertNil(fixture.scheduler.lastGeneration)
        XCTAssertTrue(try fixture.coordinator.automaticBackupIsPaused())
    }

    func testSingleWriterDoesNotRewriteTheSameGeneration() throws {
        let fixture = try makeFixture()
        var inFlight = 0
        var peak = 0
        let hold = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        fixture.scheduler.replaceBackup {
            inFlight += 1
            peak = max(peak, inFlight)
            started.signal()
            hold.wait()
            defer {
                inFlight -= 1
                finished.signal()
            }
            return try fixture.vault.backUpToICloud(
                using: fixture.coordinator,
                settings: fixture.settings
            )
        }
        fixture.scheduler.noteSuccessfulChange()
        let worker = DispatchQueue(label: "askkey.backup.writer")
        worker.async { fixture.clock.fireAll() }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        hold.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(peak, 1)
        let manifests = try fixture.cloud.list(prefix: "askkey-backup/")
            .filter { $0.hasSuffix("/manifest.json") }
        XCTAssertEqual(manifests.count, 1)
    }

    func testSnapshotOmitsAccessRecordsPauseClientAndAuthPreferences() throws {
        let fixture = try makeFixture()
        fixture.vault.recordCredentialAccess(
            .init(
                timestamp: Date(),
                credentialID: "hidden-from-backup",
                operation: .runtimeRead,
                result: .allowed,
                callerHint: "codex",
                declaredPurpose: "should-not-appear"
            )
        )
        try fixture.vault.pauseAgentAccess(using: .allow)
        try fixture.vault.resumeAgentAccess(using: .allow)
        _ = try fixture.vault.createTextCredential(
            .init(name: "Visible", value: "KEEP", permission: .ask),
            using: .allow
        )
        fixture.scheduler.noteSuccessfulChange()
        fixture.clock.fireAll()
        let snapshot = try fixture.coordinator.restore()
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("hidden-from-backup"))
        XCTAssertFalse(encoded.contains("should-not-appear"))
        XCTAssertFalse(encoded.contains("codex"))
        XCTAssertFalse(encoded.contains("readApproval"))
        XCTAssertEqual(snapshot.credentials.map(\.displayName), ["Visible"])
        XCTAssertEqual(
            Mirror(reflecting: snapshot.settings).children.map(\.label),
            ["languageMode", "appearanceMode", "defaultTimedAllowanceMinutes", "launchAtLogin"]
        )
    }

    func testVaultNotifiesOnlySnapshotRelevantWrites() throws {
        let fixture = try makeFixture()
        var notes = 0
        fixture.vault.onSnapshotRelevantChange = { notes += 1 }
        _ = try fixture.vault.createTextCredential(
            .init(
                name: "Mapped",
                value: "VALUE",
                groupName: "Work",
                environmentVariable: "ASKKEY_MAPPED",
                permission: .ask
            ),
            using: .allow
        )
        try fixture.vault.createCredentialGroup("Empty", using: .allow)
        try fixture.vault.updateCredentialMetadata(
            id: try XCTUnwrap(fixture.vault.listTextCredentials().first?.id),
            name: "Mapped",
            usageInstructions: "updated",
            groupName: "Work",
            permission: .allowed,
            expiresAt: nil,
            using: .allow
        )
        fixture.vault.recordCredentialAccess(
            .init(
                timestamp: Date(),
                credentialID: "audit-only",
                operation: .runtimeRead,
                result: .allowed,
                callerHint: "cursor",
                declaredPurpose: "not-a-backup-trigger"
            )
        )
        XCTAssertEqual(notes, 3)
    }
}

final class ICloudBackupCapabilityInspectionTests: XCTestCase {
    func testReleaseMissingContainerOrEntitlementFailsClosed() {
        let missing = ICloudBackupCapabilityRequest(
            bundleIdentifier: "com.sudohg.askkey.app",
            infoPlistContainerIdentifier: nil,
            entitlementContainerIdentifiers: [],
            signing: .init(
                teamIdentifier: "TEAMID1234",
                identityKind: .developerID,
                codesignEntitlementContainers: [],
                isFixture: false
            )
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(missing),
            .releaseMaterialsMissing
        )
    }

    func testDevelopmentAdHocBuildIsHonestlyUnavailable() {
        let request = ICloudBackupCapabilityRequest(
            bundleIdentifier: "com.sudohg.askkey.app.dev",
            infoPlistContainerIdentifier: nil,
            entitlementContainerIdentifiers: [],
            signing: .init(
                teamIdentifier: nil,
                identityKind: .adHoc,
                codesignEntitlementContainers: [],
                isFixture: false
            )
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(request),
            .developmentUnavailable
        )
        XCTAssertTrue(
            ICloudBackupCapabilityInspection.nextStep(for: .developmentUnavailable)
                .contains("official")
        )
    }

    func testLokaliteContainerIsRejected() {
        XCTAssertThrowsError(
            try ICloudBackupCapabilityInspection.validateReleaseContainerIdentifier(
                "iCloud.com.lokalite.vault"
            )
        )
        let request = ICloudBackupCapabilityRequest(
            bundleIdentifier: "com.sudohg.askkey.app",
            infoPlistContainerIdentifier: "iCloud.com.lokalite.vault",
            entitlementContainerIdentifiers: ["iCloud.com.lokalite.vault"],
            signing: .init(
                teamIdentifier: "TEAMID1234",
                identityKind: .developerID,
                codesignEntitlementContainers: ["iCloud.com.lokalite.vault"],
                isFixture: false
            )
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(request),
            .forbiddenContainer
        )
    }

    func testFixtureSigningNeverClaimsProductionReady() {
        let request = ICloudBackupCapabilityRequest(
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
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(request),
            .fixtureUnproven
        )
        XCTAssertNotEqual(
            ICloudBackupCapabilityInspection.decide(request),
            .ready(containerIdentifier: "iCloud.com.sudohg.askkey.fixture")
        )
    }

    func testTeamAloneDoesNotClassifyAsDeveloperID() {
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.classifySigningIdentity(
                teamIdentifier: "TEAMID1234",
                certificateSummaries: ["Apple Development: Hogan (TEAMID1234)"]
            ),
            .unknown
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.classifySigningIdentity(
                teamIdentifier: "TEAMID1234",
                certificateSummaries: []
            ),
            .unknown
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.classifySigningIdentity(
                teamIdentifier: nil,
                certificateSummaries: []
            ),
            .adHoc
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.classifySigningIdentity(
                teamIdentifier: "TEAMID1234",
                certificateSummaries: ["Developer ID Application: AskKey (TEAMID1234)"]
            ),
            .developerID
        )
        let development = ICloudBackupCapabilityRequest(
            bundleIdentifier: "com.sudohg.askkey.app",
            infoPlistContainerIdentifier: "iCloud.com.sudohg.askkey",
            entitlementContainerIdentifiers: ["iCloud.com.sudohg.askkey"],
            signing: .init(
                teamIdentifier: "TEAMID1234",
                identityKind: ICloudBackupCapabilityInspection.classifySigningIdentity(
                    teamIdentifier: "TEAMID1234",
                    certificateSummaries: ["Apple Development: Hogan (TEAMID1234)"]
                ),
                codesignEntitlementContainers: ["iCloud.com.sudohg.askkey"],
                isFixture: false
            )
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(development),
            .developmentUnavailable
        )
    }

    func testValidReleaseMaterialsAreReadyOnlyWhenNotAFixture() throws {
        try ICloudBackupCapabilityInspection.validateReleaseContainerIdentifier(
            "iCloud.com.sudohg.askkey"
        )
        let request = ICloudBackupCapabilityRequest(
            bundleIdentifier: "com.sudohg.askkey.app",
            infoPlistContainerIdentifier: "iCloud.com.sudohg.askkey",
            entitlementContainerIdentifiers: ["iCloud.com.sudohg.askkey"],
            signing: .init(
                teamIdentifier: "TEAMID1234",
                identityKind: .developerID,
                codesignEntitlementContainers: ["iCloud.com.sudohg.askkey"],
                isFixture: false
            )
        )
        XCTAssertEqual(
            ICloudBackupCapabilityInspection.decide(request),
            .ready(containerIdentifier: "iCloud.com.sudohg.askkey")
        )
    }
}

private final class SchedulerChangeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AutomaticBackupChangeLedger()
    var snapshot: AutomaticBackupChangeLedger {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var hasUnconfirmedChange: Bool { snapshot.hasUnconfirmedChange }
}

private final class ManualBackupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [() -> Void] = []

    func schedule(delay: TimeInterval, work: @escaping () -> Void) -> AutomaticICloudBackupScheduler.Cancellation {
        lock.lock()
        var alive = true
        self.work.append {
            if alive { work() }
        }
        lock.unlock()
        return .init {
            alive = false
        }
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

private struct SchedulerFixture {
    let vault: Vault
    let coordinator: ICloudBackupCoordinator
    let cloud: ICloudFileBackupStore
    let state: SchedulerBackupState
    let material: ICloudBackupKeyMaterial
    let scheduler: AutomaticICloudBackupScheduler
    let clock: ManualBackupClock
    let settings = ICloudBackupSettings(
        languageMode: "system",
        appearanceMode: "system",
        defaultTimedAllowanceMinutes: 30,
        launchAtLogin: false
    )
}

private func makeFixture(
    vault existingVault: Vault? = nil,
    coordinator existingCoordinator: ICloudBackupCoordinator? = nil,
    ledger: SchedulerChangeLedger = SchedulerChangeLedger()
) throws -> SchedulerFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AskKeyAutoBackup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cloud = try ICloudFileBackupStore(
        provider: SchedulerContainer(root: root),
        fileManager: SchedulerFileManager(root: root)
    )
    let state = SchedulerBackupState()
    let material = try ICloudBackupKeyMaterial.generate()
    let coordinator = try existingCoordinator ?? ICloudBackupCoordinator(
        store: cloud,
        material: material,
        stateStore: state
    )
    let vault: Vault
    if let existingVault {
        vault = existingVault
    } else {
        let store = try VaultStore(path: root.appendingPathComponent("vault.db").path)
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        vault = Vault(store: store, key: key)
        try vault.beginManagementSession(using: .allow)
    }
    let clock = ManualBackupClock()
    let scheduler = AutomaticICloudBackupScheduler(
        backup: {
            try vault.backUpToICloud(using: coordinator, settings: ICloudBackupSettings(
                languageMode: "system",
                appearanceMode: "system",
                defaultTimedAllowanceMinutes: 30,
                launchAtLogin: false
            ))
        },
        isEnabled: { try !state.isAutomaticBackupPaused(namespace: material.recoveryKey.keyID) },
        hasPendingUpload: { try state.pendingUpload(namespace: material.recoveryKey.keyID) != nil },
        loadLedger: { ledger.snapshot },
        persistLedger: { ledger.snapshot = $0 },
        schedule: clock.schedule
    )
    return SchedulerFixture(
        vault: vault,
        coordinator: coordinator,
        cloud: cloud,
        state: state,
        material: material,
        scheduler: scheduler,
        clock: clock
    )
}

private struct SchedulerContainer: ICloudBackupContainerProviding {
    let root: URL
    func containerURL() -> URL? { root }
}

private final class SchedulerFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override var temporaryDirectory: URL { root }
}

private final class SchedulerBackupState: ICloudBackupLocalStateStore {
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

