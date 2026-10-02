import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import AskKeyCore

final class ICloudBackupTests: XCTestCase {
    func testGenerationRoundTripsOnlyAfterManifestBlobDigestAndAEADValidate() throws {
        let store = MemoryBackupStore()
        let key = try BackupRecoveryKey.generate()
        let backup = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerA,
            stateStore: MemoryBackupStateStore()
        )
        let payload = snapshot("SECRET_VALUE")

        let generation = try backup.backUp(snapshot: payload, createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        XCTAssertEqual(try backup.restore(), payload)
        XCTAssertTrue(store.paths.contains(where: { $0.contains(generation.id) && $0.hasSuffix("manifest.json") }))
        XCTAssertTrue(store.paths.contains(where: { $0.contains(generation.id) && $0.hasSuffix("blob") }))
        XCTAssertFalse(store.paths.contains(where: { $0.contains("Production API Key") }))
        XCTAssertFalse(store.allData.contains(where: { $0.range(of: Data("Production API Key".utf8)) != nil }))
        XCTAssertFalse(store.allData.contains(where: { $0.range(of: Data("SECRET_VALUE".utf8)) != nil }))
    }

    func testUploadedBlobAndManifestMustReadBackAndVerifyBeforeCurrentAdvances() throws {
        for suffix in ["/blob", "/manifest.json"] {
            let store = MemoryBackupStore()
            let backup = try makeBackup(store: store)
            store.corruptNextCreateSuffix = suffix

            XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("payload"))) { error in
                guard case ICloudBackupError.invalidGeneration = error else {
                    return XCTFail("Expected invalid uploaded generation, got \(error)")
                }
            }
            XCTAssertThrowsError(try backup.restore()) { error in
                XCTAssertEqual(error as? ICloudBackupError, .noValidGeneration)
            }
            XCTAssertFalse(store.paths.contains(where: { $0.hasSuffix("/current.json") }))
            _ = try backup.backUp(snapshot: snapshot("retry"))
            XCTAssertEqual(try backup.restore(), snapshot("retry"))
        }
    }

    func testCorruptCurrentFallsBackToVerifiedPrevious() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        let previous = snapshot("previous")
        _ = try backup.backUp(snapshot: previous)
        let current = try backup.backUp(snapshot: snapshot("current"))
        try store.mutate(pathSuffix: "\(current.id)/blob") { $0[0] ^= 0xff }

        XCTAssertEqual(try backup.restore(), previous)
    }

    func testUnknownVersionAndKeyIDFailClosed() throws {
        for field in ["formatVersion", "keyID"] {
            let store = MemoryBackupStore()
            let backup = try makeBackup(store: store)
            let generation = try backup.backUp(snapshot: snapshot("payload"))
            try store.mutateJSON(pathSuffix: "\(generation.id)/manifest.json") { object in
                object[field] = field == "formatVersion" ? 999 : "unknown-key"
            }

            XCTAssertThrowsError(try backup.restore()) { error in
                XCTAssertEqual(error as? ICloudBackupError, .noValidGeneration)
            }
        }
    }

    func testConflictCopyAndDifferentWriterPauseAutomaticBackup() throws {
        let key = try BackupRecoveryKey.generate()

        let conflictedStore = MemoryBackupStore()
        conflictedStore.conflicts = ["askkey-backup/conflicted copy"]
        let conflictState = MemoryBackupStateStore()
        let conflicted = try ICloudBackupCoordinator(
            store: conflictedStore,
            recoveryKey: key,
            writerID: writerA,
            stateStore: conflictState
        )
        XCTAssertThrowsError(try conflicted.backUp(snapshot: snapshot(""))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .conflictCopy)
        }
        XCTAssertThrowsError(try conflicted.restore()) { error in
            XCTAssertEqual(error as? ICloudBackupError, .conflictCopy)
        }
        XCTAssertTrue(try conflicted.automaticBackupIsPaused())
        let restarted = try ICloudBackupCoordinator(
            store: conflictedStore,
            recoveryKey: key,
            writerID: writerA,
            stateStore: conflictState
        )
        XCTAssertThrowsError(try restarted.backUp(snapshot: snapshot(""))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }

        let sharedStore = MemoryBackupStore()
        _ = try ICloudBackupCoordinator(
            store: sharedStore,
            recoveryKey: key,
            writerID: writerA,
            stateStore: MemoryBackupStateStore()
        )
            .backUp(snapshot: snapshot("a"))
        let secondWriter = try ICloudBackupCoordinator(
            store: sharedStore,
            recoveryKey: key,
            writerID: writerB,
            stateStore: MemoryBackupStateStore()
        )
        XCTAssertThrowsError(try secondWriter.backUp(snapshot: snapshot("b"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .differentWriter)
        }
        XCTAssertTrue(try secondWriter.automaticBackupIsPaused())
    }

    func testConflictCopyCanBeInspectedRestoredAndExplicitlyResolvedByTakeover() throws {
        let store = MemoryBackupStore()
        let state = MemoryBackupStateStore()
        let backup = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: BackupRecoveryKey.generate(),
            writerID: writerA,
            stateStore: state
        )
        let generation = try backup.backUp(snapshot: snapshot("canonical"))
        store.conflicts = ["askkey-backup/opaque-conflicted-copy"]

        XCTAssertEqual(try backup.recoverableGenerations().map(\.id), [generation.id])
        let target = RestoreTarget()
        _ = try backup.restoreGeneration(
            generation.id,
            into: target,
            using: .allow,
            persistLocalSafetySnapshot: { _ in }
        )
        XCTAssertEqual(target.replacement?.credentials.first?.payload, .text("canonical"))
        XCTAssertTrue(try backup.automaticBackupIsPaused())

        XCTAssertThrowsError(
            try backup.resumeAfterUserTakesOwnership(of: "missing-generation")
        )
        XCTAssertFalse(store.conflicts.isEmpty)
        try backup.resumeAfterUserTakesOwnership(of: generation.id)
        XCTAssertTrue(store.conflicts.isEmpty)
        _ = try backup.backUp(snapshot: snapshot("continued"))
        XCTAssertEqual(try backup.restore(), snapshot("continued"))
    }

    func testRestoreReadsDifferentWriterButPersistsPauseForFutureBackup() throws {
        let key = try BackupRecoveryKey.generate()
        let store = MemoryBackupStore()
        let foreignMaterial = try ICloudBackupKeyMaterial(recoveryKey: key, writerID: writerB)
        _ = try ICloudBackupCoordinator(
            store: store,
            material: foreignMaterial,
            stateStore: MemoryBackupStateStore()
        ).backUp(snapshot: snapshot("foreign"))
        let state = MemoryBackupStateStore()
        let local = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerA,
            stateStore: state
        )

        XCTAssertEqual(try local.restore(), snapshot("foreign"))
        XCTAssertTrue(try local.automaticBackupIsPaused())
        XCTAssertThrowsError(try local.backUp(snapshot: snapshot("blocked"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
    }

    func testHumanTakeoverResolvesDifferentWriterAndResumesFromChosenGeneration() throws {
        let key = try BackupRecoveryKey.generate()
        let store = MemoryBackupStore()
        let source = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerA,
            stateStore: MemoryBackupStateStore()
        )
        _ = try source.backUp(snapshot: snapshot("first"))
        let selected = try source.backUp(snapshot: snapshot("second"))
        let state = MemoryBackupStateStore()
        let takeover = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerB,
            stateStore: state
        )
        XCTAssertThrowsError(try takeover.backUp(snapshot: snapshot("blocked")))

        try takeover.resumeAfterUserTakesOwnership(of: selected.id)
        _ = try takeover.backUp(snapshot: snapshot("after takeover"))

        XCTAssertFalse(try takeover.automaticBackupIsPaused())
        XCTAssertEqual(try takeover.restore(), snapshot("after takeover"))
    }

    func testHumanTakeoverCanRetryEveryMutableStepFailure() throws {
        for suffix in ["/writer.json", "/previous.json", "/current.json"] {
            let fixture = try makeTakeoverFixture()
            fixture.store.failNextReplaceSuffix = suffix

            XCTAssertThrowsError(try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id))
            XCTAssertTrue(try fixture.coordinator.automaticBackupIsPaused())
            try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id)
            _ = try fixture.coordinator.backUp(snapshot: snapshot("resumed"))
            XCTAssertEqual(try fixture.coordinator.restore(), snapshot("resumed"))
        }

        let fixture = try makeTakeoverFixture()
        fixture.state.failNextWrite = true
        XCTAssertThrowsError(try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id))
        XCTAssertTrue(try fixture.coordinator.automaticBackupIsPaused())
        try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id)
    }

    func testFailedTakeoverPreservesConflictCopyUntilEveryLaterMutationSucceeds() throws {
        for failure in TakeoverFailure.allCases {
            let fixture = try makeTakeoverFixture()
            fixture.store.conflicts = ["askkey-backup/opaque-conflicted-copy"]
            switch failure {
            case .childClaimDelete:
                fixture.store.failNextDelete = true
            case .writer:
                fixture.store.failNextReplaceSuffix = "/writer.json"
            case .previous:
                fixture.store.failNextReplaceSuffix = "/previous.json"
            case .current:
                fixture.store.failNextReplaceSuffix = "/current.json"
            case .acceptedTakeover:
                fixture.state.failOnWriteNumber = 1
            case .automaticBackupResume:
                fixture.state.failOnWriteNumber = 2
            }

            XCTAssertThrowsError(
                try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id),
                "Expected injected \(failure) failure"
            )
            XCTAssertFalse(fixture.store.conflicts.isEmpty, "Lost conflict copy after \(failure)")
            XCTAssertTrue(try fixture.coordinator.automaticBackupIsPaused())

            try fixture.coordinator.resumeAfterUserTakesOwnership(of: fixture.selected.id)
            XCTAssertTrue(fixture.store.conflicts.isEmpty)
            XCTAssertFalse(try fixture.coordinator.automaticBackupIsPaused())
        }
    }

    func testNewRecoveryMaterialCreatesASeparateNamespaceAndOldKeyStillRestores() throws {
        let store = MemoryBackupStore()
        let oldMaterial = try ICloudBackupKeyMaterial.generate()
        let newMaterial = try ICloudBackupKeyMaterial.generate()
        let oldBackup = try ICloudBackupCoordinator(
            store: store,
            material: oldMaterial,
            stateStore: MemoryBackupStateStore()
        )
        let newBackup = try ICloudBackupCoordinator(
            store: store,
            material: newMaterial,
            stateStore: MemoryBackupStateStore()
        )

        _ = try oldBackup.backUp(snapshot: snapshot("old namespace"))
        _ = try newBackup.backUp(snapshot: snapshot("new namespace"))

        XCTAssertNotEqual(oldMaterial.recoveryKey.keyID, newMaterial.recoveryKey.keyID)
        XCTAssertEqual(try oldBackup.restore(), snapshot("old namespace"))
        XCTAssertEqual(try newBackup.restore(), snapshot("new namespace"))
    }

    func testStoppingBackupAndDeletingCloudNamespaceAreSeparateConfirmedActions() throws {
        let cloud = MemoryBackupStore()
        let materials = MemoryBackupMaterialStore()
        let state = MemoryBackupStateStore()
        let manager = ICloudBackupNamespaceManager(cloud: cloud, materials: materials, state: state)
        let material = try manager.createNewBackupNamespace()
        let backup = try ICloudBackupCoordinator(store: cloud, material: material, stateStore: state)
        _ = try backup.backUp(snapshot: snapshot("kept until confirmed"))

        try manager.stopAutomaticBackups(namespace: material.recoveryKey.keyID)
        XCTAssertFalse(cloud.paths.isEmpty)
        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("must stay stopped"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
        XCTAssertThrowsError(
            try manager.deleteCloudNamespace(material.recoveryKey.keyID, using: .deny)
        )
        XCTAssertFalse(cloud.paths.isEmpty)

        try manager.deleteCloudNamespace(material.recoveryKey.keyID, using: .allow)
        XCTAssertTrue(cloud.paths.isEmpty)
        XCTAssertNil(try materials.load(keyID: material.recoveryKey.keyID))
        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("must not recreate"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
    }

    func testLocalEraseStopBlocksEveryNamespaceUntilANewInstallationCreatesOne() throws {
        let suite = "AskKeyBackupEraseStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryBackupStore()
        let state = UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        let oldMaterial = try ICloudBackupKeyMaterial.generate()
        state.stopAllAutomaticBackups()
        let stopped = try ICloudBackupCoordinator(
            store: cloud,
            material: oldMaterial,
            stateStore: state
        )

        XCTAssertThrowsError(try stopped.backUp(snapshot: snapshot("blocked"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }

        let manager = ICloudBackupNamespaceManager(
            cloud: cloud,
            materials: MemoryBackupMaterialStore(),
            state: state
        )
        let newMaterial = try manager.createNewBackupNamespace()
        let restarted = try ICloudBackupCoordinator(
            store: cloud,
            material: newMaterial,
            stateStore: state
        )
        _ = try restarted.backUp(snapshot: snapshot("new installation"))
        XCTAssertFalse(try restarted.automaticBackupIsPaused())
    }

    func testStopWaitsForInFlightBackupThenPreventsFurtherWrites() throws {
        let cloud = MemoryBackupStore()
        let materials = MemoryBackupMaterialStore()
        let state = MemoryBackupStateStore()
        let manager = ICloudBackupNamespaceManager(cloud: cloud, materials: materials, state: state)
        let material = try manager.createNewBackupNamespace()
        let backup = try ICloudBackupCoordinator(store: cloud, material: material, stateStore: state)
        cloud.blockNextBlobCreate = true
        let inFlightSnapshot = snapshot("in flight")
        let backupResult = AsyncResult<ICloudBackupGeneration>()
        let backupDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            backupResult.set(Result { try backup.backUp(snapshot: inFlightSnapshot) })
            backupDone.signal()
        }
        XCTAssertEqual(cloud.blobCreateStarted.wait(timeout: .now() + 2), .success)

        let stopResult = AsyncResult<Void>()
        let stopDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stopResult.set(Result { try manager.stopAutomaticBackups(namespace: material.recoveryKey.keyID) })
            stopDone.signal()
        }
        XCTAssertEqual(stopDone.wait(timeout: .now() + 0.05), .timedOut)
        cloud.allowBlobCreate.signal()
        XCTAssertEqual(backupDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopDone.wait(timeout: .now() + 2), .success)
        _ = try backupResult.get().get()
        try stopResult.get().get()

        XCTAssertTrue(try backup.automaticBackupIsPaused())
        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("blocked")))
    }

    func testLocalEraseGlobalStopWaitsForInFlightBackup() throws {
        let suite = "AskKeyGlobalBackupStopTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryBackupStore()
        let material = try ICloudBackupKeyMaterial.generate()
        let state = UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        let backup = try ICloudBackupCoordinator(
            store: cloud,
            material: material,
            stateStore: state
        )
        cloud.blockNextBlobCreate = true
        let inFlight = snapshot("in flight")
        let backupDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? backup.backUp(snapshot: inFlight)
            backupDone.signal()
        }
        XCTAssertEqual(cloud.blobCreateStarted.wait(timeout: .now() + 2), .success)

        let stopDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            state.stopAllAutomaticBackups()
            stopDone.signal()
        }
        XCTAssertEqual(stopDone.wait(timeout: .now() + 0.05), .timedOut)
        cloud.allowBlobCreate.signal()
        XCTAssertEqual(backupDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopDone.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(try backup.automaticBackupIsPaused())
    }

    func testStopQuiescesAcrossSeparateStateStoreInstancesForSameDefaults() throws {
        let suite = "AskKeyBackupStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cloud = MemoryBackupStore()
        let materials = MemoryBackupMaterialStore()
        let coordinatorState = UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        let managerState = UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        let manager = ICloudBackupNamespaceManager(
            cloud: cloud,
            materials: materials,
            state: managerState
        )
        let material = try manager.createNewBackupNamespace()
        let backup = try ICloudBackupCoordinator(
            store: cloud,
            material: material,
            stateStore: coordinatorState
        )
        cloud.blockNextBlobCreate = true
        let backupDone = DispatchSemaphore(value: 0)
        let backupResult = AsyncResult<ICloudBackupGeneration>()
        let inFlight = snapshot("in flight")
        DispatchQueue.global().async {
            backupResult.set(Result { try backup.backUp(snapshot: inFlight) })
            backupDone.signal()
        }
        XCTAssertEqual(cloud.blobCreateStarted.wait(timeout: .now() + 2), .success)

        let stopDone = DispatchSemaphore(value: 0)
        let stopResult = AsyncResult<Void>()
        DispatchQueue.global().async {
            stopResult.set(Result {
                try manager.stopAutomaticBackups(namespace: material.recoveryKey.keyID)
            })
            stopDone.signal()
        }
        XCTAssertEqual(stopDone.wait(timeout: .now() + 0.05), .timedOut)
        cloud.allowBlobCreate.signal()
        XCTAssertEqual(backupDone.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(stopDone.wait(timeout: .now() + 2), .success)
        _ = try backupResult.get().get()
        try stopResult.get().get()
        XCTAssertTrue(try backup.automaticBackupIsPaused())
    }

    func testNamespaceDeletionRetriesCloudAndMaterialStepFailures() throws {
        for failCloudDelete in [true, false] {
            let cloud = MemoryBackupStore()
            let materials = MemoryBackupMaterialStore()
            let state = MemoryBackupStateStore()
            let manager = ICloudBackupNamespaceManager(cloud: cloud, materials: materials, state: state)
            let material = try manager.createNewBackupNamespace()
            let backup = try ICloudBackupCoordinator(store: cloud, material: material, stateStore: state)
            _ = try backup.backUp(snapshot: snapshot("payload"))
            if failCloudDelete {
                cloud.failNextDelete = true
            } else {
                materials.failNextDelete = true
            }

            XCTAssertThrowsError(
                try manager.deleteCloudNamespace(material.recoveryKey.keyID, using: .allow)
            )
            XCTAssertTrue(try backup.automaticBackupIsPaused())
            try manager.deleteCloudNamespace(material.recoveryKey.keyID, using: .allow)
            XCTAssertTrue(cloud.paths.isEmpty)
            XCTAssertNil(try materials.load(keyID: material.recoveryKey.keyID))
        }
    }

    func testRolledBackCurrentPointerWaitsWhenManifestListingIsBehind() throws {
        let store = MemoryBackupStore()
        let key = try BackupRecoveryKey.generate()
        let state = MemoryBackupStateStore()
        let backup = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerA,
            stateStore: state
        )
        let first = try backup.backUp(snapshot: snapshot("first"))
        _ = try backup.backUp(snapshot: snapshot("second"))
        try store.setHint(named: "current", generationID: first.id)
        try store.removeHint(named: "previous")
        store.hideManifestList = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("next"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .propagationPending)
        }
        XCTAssertFalse(try backup.automaticBackupIsPaused())
    }

    func testChildClaimRecoversExistingChildWhenDirectoryListingOmitsIt() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        let first = try backup.backUp(snapshot: snapshot("first"))
        let second = try backup.backUp(snapshot: snapshot("second"))
        try store.setHint(named: "current", generationID: first.id)
        try store.setHint(named: "previous", generationID: first.id)
        store.hiddenManifestGenerationID = second.id

        let recovered = try backup.backUp(snapshot: snapshot("must not fork"))

        XCTAssertEqual(recovered.id, second.id)
        XCTAssertEqual(try backup.restore(), snapshot("second"))
        XCTAssertEqual(store.generationIDs.count, 2)
    }

    func testForkedParentPersistsPauseAndRestartCannotContinueBackup() throws {
        let suite = "AskKeyForkStateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let material = try ICloudBackupKeyMaterial.generate()
        let base = MemoryBackupStore()
        let parentWriter = try ICloudBackupCoordinator(
            store: base,
            material: material,
            stateStore: UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        )
        _ = try parentWriter.backUp(snapshot: snapshot("parent"))
        let left = base.clone()
        let right = base.clone()
        _ = try ICloudBackupCoordinator(
            store: left,
            material: material,
            stateStore: UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        ).backUp(snapshot: snapshot("left child"))
        _ = try ICloudBackupCoordinator(
            store: right,
            material: material,
            stateStore: UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        ).backUp(snapshot: snapshot("right child"))
        left.mergeGenerationObjects(from: right)

        let detector = try ICloudBackupCoordinator(
            store: left,
            material: material,
            stateStore: UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        )
        XCTAssertThrowsError(try detector.backUp(snapshot: snapshot("must not continue"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .forkDetected)
        }
        XCTAssertTrue(try detector.automaticBackupIsPaused())

        let restarted = try ICloudBackupCoordinator(
            store: left,
            material: material,
            stateStore: UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: try makePendingUploadDirectory()
        )
        )
        XCTAssertThrowsError(try restarted.backUp(snapshot: snapshot("still blocked"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
    }

    func testForkedGenerationsCanBeListedAndChosenForFullRestoreWhileBackupStaysPaused() throws {
        let material = try ICloudBackupKeyMaterial.generate()
        let base = MemoryBackupStore()
        let parent = try ICloudBackupCoordinator(
            store: base,
            material: material,
            stateStore: MemoryBackupStateStore()
        )
        _ = try parent.backUp(snapshot: snapshot("parent"))
        let left = base.clone()
        let right = base.clone()
        let leftChild = try ICloudBackupCoordinator(
            store: left,
            material: material,
            stateStore: MemoryBackupStateStore()
        ).backUp(snapshot: snapshot("left child"))
        _ = try ICloudBackupCoordinator(
            store: right,
            material: material,
            stateStore: MemoryBackupStateStore()
        ).backUp(snapshot: snapshot("right child"))
        left.mergeGenerationObjects(from: right)
        let detector = try ICloudBackupCoordinator(
            store: left,
            material: material,
            stateStore: MemoryBackupStateStore()
        )

        let recoverableIDs = Set(try detector.recoverableGenerations().map(\.id))
        XCTAssertEqual(recoverableIDs.count, 3)
        XCTAssertTrue(recoverableIDs.contains(leftChild.id))
        let target = RestoreTarget()
        let restored = try detector.restoreGeneration(
            leftChild.id,
            into: target,
            using: .allow,
            persistLocalSafetySnapshot: { _ in }
        )

        XCTAssertEqual(restored.id, leftChild.id)
        XCTAssertEqual(target.replacement?.credentials.first?.payload, .text("left child"))
        XCTAssertTrue(try detector.automaticBackupIsPaused())
        try detector.resumeAfterUserTakesOwnership(of: leftChild.id)
        _ = try detector.backUp(snapshot: snapshot("continued chosen branch"))
        XCTAssertEqual(try detector.restore(), snapshot("continued chosen branch"))
    }

    func testManifestCommittedBeforeCurrentFailureIsFinalizedOnRetry() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        store.failNextCurrentReplacement = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("committed")))
        let committedID = try XCTUnwrap(store.generationIDs.first)
        let recovered = try backup.backUp(snapshot: snapshot("ignored retry payload"))

        XCTAssertEqual(recovered.id, committedID)
        XCTAssertEqual(try backup.restore(), snapshot("committed"))
        XCTAssertEqual(store.generationIDs.count, 1)
    }

    func testNewDeviceRestoresVerifiedFirstGenerationWhenCurrentHintNeverCommitted() throws {
        let store = MemoryBackupStore()
        let material = try ICloudBackupKeyMaterial.generate()
        let state = MemoryBackupStateStore()
        let writer = try ICloudBackupCoordinator(store: store, material: material, stateStore: state)
        store.failNextCurrentReplacement = true

        XCTAssertThrowsError(try writer.backUp(snapshot: snapshot("recoverable without hint")))
        let newDevice = try ICloudBackupCoordinator(
            store: store,
            material: material,
            stateStore: MemoryBackupStateStore()
        )

        XCTAssertEqual(try newDevice.restore(), snapshot("recoverable without hint"))
    }

    func testNewDeviceUsesOnlyRecoveryKeyForReadAndFullReplacementButCannotBackUp() throws {
        let store = MemoryBackupStore()
        let oldMaterial = try ICloudBackupKeyMaterial.generate()
        let oldDevice = try ICloudBackupCoordinator(
            store: store,
            material: oldMaterial,
            stateStore: MemoryBackupStateStore()
        )
        let original = try oldDevice.backUp(snapshot: snapshot("recovery-key-only"))
        let newDeviceState = MemoryBackupStateStore()
        let newDevice = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: oldMaterial.recoveryKey,
            writerID: writerB,
            stateStore: newDeviceState
        )

        XCTAssertEqual(try newDevice.restore(), snapshot("recovery-key-only"))
        let target = RestoreTarget()
        try newDevice.restore(into: target, using: .allow) { _ in }
        XCTAssertEqual(target.replacement?.credentials.first?.payload, .text("recovery-key-only"))
        XCTAssertThrowsError(try newDevice.backUp(snapshot: snapshot("must take over first"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
        XCTAssertTrue(try newDevice.automaticBackupIsPaused())

        let restarted = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: oldMaterial.recoveryKey,
            writerID: writerB,
            stateStore: newDeviceState
        )
        XCTAssertThrowsError(try restarted.backUp(snapshot: snapshot("still paused"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .automaticBackupPaused)
        }
        try restarted.resumeAfterUserTakesOwnership(of: original.id)
        _ = try restarted.backUp(snapshot: snapshot("after explicit takeover"))
        XCTAssertEqual(try restarted.restore(), snapshot("after explicit takeover"))
    }

    func testBlobAndManifestWriteFailuresCleanUncommittedGenerationForRetry() throws {
        for suffix in ["/blob", "/manifest.json"] {
            let store = MemoryBackupStore()
            let backup = try makeBackup(store: store)
            store.failNextCreateSuffix = suffix

            XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("failed")))
            XCTAssertTrue(store.generationIDs.isEmpty)
            _ = try backup.backUp(snapshot: snapshot("retry"))
            XCTAssertEqual(try backup.restore(), snapshot("retry"))
        }
    }

    func testAlreadyExistingImmutableFileIsNeverDeletedByFailedGenerationCleanup() throws {
        for suffix in ["/blob", "/manifest.json"] {
            let store = MemoryBackupStore()
            let backup = try makeBackup(store: store)
            store.collisionSuffix = suffix

            XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("collision")))

            XCTAssertTrue(store.allData.contains(store.collisionData))
            _ = try backup.backUp(snapshot: snapshot("retry"))
            XCTAssertEqual(try backup.restore(), snapshot("retry"))
        }
    }

    func testGenerationCleanupFailureReportsPrimaryAndCleanupErrors() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        store.failNextCreateSuffix = "/manifest.json"
        store.failNextDelete = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("failed"))) { error in
            guard case ICloudBackupError.cleanupFailed(let primary, let cleanup) = error else {
                return XCTFail("Expected combined cleanup error, got \(error)")
            }
            XCTAssertTrue(primary.contains("injected"))
            XCTAssertTrue(cleanup.contains("injected"))
        }
        _ = try backup.backUp(snapshot: snapshot("retry"))
        XCTAssertEqual(try backup.restore(), snapshot("retry"))
    }

    func testTamperedCleanupStateCannotDeleteAnotherNamespaceOrCurrentGeneration() throws {
        let store = MemoryBackupStore()
        let material = try ICloudBackupKeyMaterial.generate()
        let state = MemoryBackupStateStore()
        let backup = try ICloudBackupCoordinator(store: store, material: material, stateStore: state)
        let current = try backup.backUp(snapshot: snapshot("protected"))
        let currentManifest = try XCTUnwrap(
            store.paths.first(where: { $0.contains(current.id) && $0.hasSuffix("/manifest.json") })
        )

        try state.setPendingCleanupPaths([currentManifest], namespace: material.recoveryKey.keyID)
        XCTAssertThrowsError(
            try ICloudBackupCoordinator(store: store, material: material, stateStore: state)
        ) { error in
            XCTAssertEqual(error as? ICloudBackupError, .invalidCleanupState)
        }
        XCTAssertEqual(try backup.restore(), snapshot("protected"))

        let otherMaterial = try ICloudBackupKeyMaterial.generate()
        let otherState = MemoryBackupStateStore()
        try otherState.setPendingCleanupPaths([currentManifest], namespace: otherMaterial.recoveryKey.keyID)
        XCTAssertThrowsError(
            try ICloudBackupCoordinator(store: store, material: otherMaterial, stateStore: otherState)
        ) { error in
            XCTAssertEqual(error as? ICloudBackupError, .invalidCleanupState)
        }
        XCTAssertEqual(try backup.restore(), snapshot("protected"))
    }

    func testPreviousHintFailureFinalizesCommittedGenerationOnRetry() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        _ = try backup.backUp(snapshot: snapshot("first"))
        store.failNextReplaceSuffix = "/previous.json"

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("second")))
        _ = try backup.backUp(snapshot: snapshot("ignored"))

        XCTAssertEqual(try backup.restore(), snapshot("second"))
        XCTAssertFalse(try backup.automaticBackupIsPaused())
    }

    func testNonFirstCurrentFailureFinalizesCommittedChildInsteadOfPausing() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        _ = try backup.backUp(snapshot: snapshot("first"))
        _ = try backup.backUp(snapshot: snapshot("second"))
        let existingIDs = Set(store.generationIDs)
        store.failNextCurrentReplacement = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("third")))
        let committedID = try XCTUnwrap(Set(store.generationIDs).subtracting(existingIDs).first)
        let recovered = try backup.backUp(snapshot: snapshot("ignored"))

        XCTAssertEqual(recovered.id, committedID)
        XCTAssertEqual(try backup.restore(), snapshot("third"))
        XCTAssertFalse(try backup.automaticBackupIsPaused())
    }

    func testSuccessfulBackupsRetainOnlyCurrentAndPreviousGenerations() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        _ = try backup.backUp(snapshot: snapshot("first"))
        _ = try backup.backUp(snapshot: snapshot("second"))
        _ = try backup.backUp(snapshot: snapshot("third"))

        XCTAssertEqual(store.generationIDs.count, 2)
        XCTAssertEqual(try backup.restore(), snapshot("third"))
    }

    func testPruneFailureLeavesCommittedCurrentRecoverableAndRetriesLater() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        _ = try backup.backUp(snapshot: snapshot("first"))
        _ = try backup.backUp(snapshot: snapshot("second"))
        store.failNextDelete = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("third")))
        XCTAssertEqual(try backup.restore(), snapshot("third"))
        _ = try backup.backUp(snapshot: snapshot("fourth"))
        XCTAssertEqual(store.generationIDs.count, 2)
    }

    func testContainerListingFailurePropagatesInsteadOfCreatingANewRoot() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        store.failListing = true

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot(""))) { error in
            guard case TestFailure.injected = error else {
                return XCTFail("Expected the storage error, got \(error)")
            }
        }
        XCTAssertTrue(store.generationIDs.isEmpty)
    }

    func testWriterMarkerFailureDoesNotStartAGenerationAndCanRetry() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        store.failNextCreateSuffix = "/writer.json"

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("failed")))
        XCTAssertTrue(store.generationIDs.isEmpty)
        _ = try backup.backUp(snapshot: snapshot("retry"))
        XCTAssertEqual(try backup.restore(), snapshot("retry"))
    }

    func testChildClaimFailureRollsBackNewWriterAndCanRetry() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        store.failNextCreateSuffix = "/children/root.json"

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("failed")))
        XCTAssertTrue(store.generationIDs.isEmpty)
        _ = try backup.backUp(snapshot: snapshot("retry"))
        XCTAssertEqual(try backup.restore(), snapshot("retry"))
    }

    func testPauseStateStoreFailureStillFailsClosedInMemory() throws {
        let store = MemoryBackupStore()
        store.conflicts = ["conflict"]
        let state = MemoryBackupStateStore()
        state.failWrites = true
        let backup = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: BackupRecoveryKey.generate(),
            writerID: writerA,
            stateStore: state
        )

        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("blocked"))) { error in
            guard case TestFailure.injected = error else {
                return XCTFail("Expected state persistence failure, got \(error)")
            }
        }
        XCTAssertTrue(try backup.automaticBackupIsPaused())
    }

    func testPointerAheadRestoresLatestVerifiedGenerationButWaitsBeforeNewBackup() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        let previousPayload = snapshot("previous")
        let previous = try backup.backUp(snapshot: previousPayload)
        let currentPayload = snapshot("current")
        _ = try backup.backUp(snapshot: currentPayload)
        try store.setHint(named: "current", generationID: "missing-generation")
        try store.setHint(named: "previous", generationID: previous.id)

        XCTAssertEqual(try backup.restore(), currentPayload)
        XCTAssertThrowsError(try backup.backUp(snapshot: snapshot("new"))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .propagationPending)
        }
        XCTAssertFalse(try backup.automaticBackupIsPaused())
    }

    func testRestoreRequiresAuthenticationPersistsSafetySnapshotAndResetsPermissions() throws {
        let store = MemoryBackupStore()
        let backup = try makeBackup(store: store)
        _ = try backup.backUp(snapshot: snapshot("restored"))
        let target = RestoreTarget()

        XCTAssertThrowsError(
            try backup.restore(into: target, using: .deny) { _ in XCTFail("must not persist") }
        ) { error in
            XCTAssertEqual(error as? ICloudBackupError, .authenticationRequired)
        }

        var persisted = Data()
        try backup.restore(into: target, using: .allow) { persisted = $0 }

        XCTAssertEqual(persisted, target.safetySnapshot)
        XCTAssertEqual(target.replacement?.credentials.first?.permission, .ask)
        XCTAssertEqual(target.replacement?.credentials.first?.payload, .text("restored"))
    }

    func testReplacementFailureIsObservableAfterSafetySnapshotPersists() throws {
        let backup = try makeBackup(store: MemoryBackupStore())
        _ = try backup.backUp(snapshot: snapshot("restored"))
        let target = FailingRestoreTarget()
        var persisted = Data()

        XCTAssertThrowsError(
            try backup.restore(into: target, using: .allow) { persisted = $0 }
        ) { error in
            guard case TestFailure.injected = error else {
                return XCTFail("Expected replacement failure, got \(error)")
            }
        }
        XCTAssertEqual(persisted, target.safetySnapshot)
    }

    func testSafetySnapshotPersistenceFailurePreventsReplacement() throws {
        let backup = try makeBackup(store: MemoryBackupStore())
        _ = try backup.backUp(snapshot: snapshot("restored"))
        let target = RestoreTarget()

        XCTAssertThrowsError(
            try backup.restore(into: target, using: .allow) { _ in throw TestFailure.injected }
        )
        XCTAssertNil(target.replacement)
    }

    func testVaultSnapshotAndFullReplacementUseWhitelistAndResetPermission() throws {
        let source = try makeVault()
        let destination = try makeVault()
        try source.vault.beginManagementSession(using: .allow)
        try destination.vault.beginManagementSession(using: .allow)
        _ = try source.vault.createTextCredential(
            .init(
                name: "Production API Key",
                value: "SECRET_VALUE",
                privateNotes: "owner only",
                groupName: "Production",
                environmentVariable: "API_KEY",
                permission: .allowed
            ),
            using: .allow
        )
        _ = try destination.vault.createTextCredential(
            .init(name: "Old Credential", value: "old", permission: .hidden),
            using: .allow
        )
        let settings = snapshot("unused").settings
        let portable = try source.vault.makeICloudBackupSnapshot(settings: settings)
        let portableJSON = String(decoding: try JSONEncoder().encode(portable), as: UTF8.self)
        for excluded in [
            "accessRecords", "requests", "timedAllowances", "temporaryFiles",
            "paused", "clientState", "biometricPreference",
        ] {
            XCTAssertFalse(portableJSON.contains(excluded))
        }
        let backup = try makeBackup(store: MemoryBackupStore())
        _ = try backup.backUp(snapshot: portable)
        var safetySnapshot = Data()
        var restoredSettings: ICloudBackupSettings?
        var currentSettings = ICloudBackupSettings(
            languageMode: "en",
            appearanceMode: "light",
            defaultTimedAllowanceMinutes: 10,
            launchAtLogin: false
        )
        var settingsObservedInsideTransaction: ICloudBackupSettings?
        let restoreTarget = try VaultICloudBackupRestoreTarget(
            vault: destination.vault,
            currentSettings: {
                settingsObservedInsideTransaction = currentSettings
                return currentSettings
            },
            applySettings: { restoredSettings = $0 }
        )
        currentSettings = ICloudBackupSettings(
            languageMode: "system",
            appearanceMode: "dark",
            defaultTimedAllowanceMinutes: 45,
            launchAtLogin: true
        )

        try backup.restore(
            into: restoreTarget,
            using: .allow,
            persistLocalSafetySnapshot: {
                safetySnapshot = $0
                XCTAssertThrowsError(
                    try destination.vault.authorizeAgentCredential(
                        named: "Old Credential",
                        operation: .read,
                        caller: .init(name: "restore-race")
                    )
                ) { error in
                    guard case VaultError.agentAccessPaused = error else {
                        return XCTFail("Expected restore quiescing, got \(error)")
                    }
                }
            }
        )

        let restored = try XCTUnwrap(destination.vault.listTextCredentials().first)
        XCTAssertEqual(try destination.vault.listTextCredentials().map(\.name), ["Production API Key"])
        XCTAssertEqual(restored.permission, .ask)
        XCTAssertEqual(
            try destination.vault.revealTextCredential(id: restored.id, using: .allow).value,
            "SECRET_VALUE"
        )
        XCTAssertFalse(safetySnapshot.isEmpty)
        XCTAssertNil(safetySnapshot.range(of: Data("Old Credential".utf8)))
        XCTAssertEqual(restoredSettings, settings)
        XCTAssertEqual(settingsObservedInsideTransaction, currentSettings)
    }

    func testRestoreSettingsJournalRecoversCrashAfterLibraryReplacement() throws {
        let source = try makeVault()
        let destination = try makeVault()
        try source.vault.beginManagementSession(using: .allow)
        try destination.vault.beginManagementSession(using: .allow)
        _ = try source.vault.createTextCredential(
            .init(name: "Restored", value: "new", permission: .allowed),
            using: .allow
        )
        _ = try destination.vault.createTextCredential(
            .init(name: "Before", value: "old", permission: .hidden),
            using: .allow
        )
        let currentSettings = snapshot("current").settings
        let restoredSettings = ICloudBackupSettings(
            languageMode: "zh-Hans",
            appearanceMode: "dark",
            defaultTimedAllowanceMinutes: 15,
            launchAtLogin: false
        )
        let portable = try source.vault.makeICloudBackupSnapshot(settings: restoredSettings)
        var applied: ICloudBackupSettings?

        XCTAssertThrowsError(
            try destination.vault.restoreLibraryFromICloudBackup(
                portable,
                currentSettings: { currentSettings },
                persistLocalSafetySnapshot: { _ in },
                applySettings: { applied = $0 },
                afterDatabaseReplace: { throw TestFailure.injected }
            )
        )
        XCTAssertEqual(try destination.vault.listTextCredentials().map(\.name), ["Restored"])
        XCTAssertNil(applied)
        XCTAssertThrowsError(
            try destination.vault.authorizeAgentCredential(
                named: "Restored",
                operation: .read,
                caller: .init(name: "crash-window")
            )
        ) { error in
            guard case VaultError.agentAccessPaused = error else {
                return XCTFail("Expected pending journal to keep Agent access paused, got \(error)")
            }
        }
        XCTAssertThrowsError(try destination.vault.resumeAgentAccess(using: .allow))
        XCTAssertThrowsError(
            try destination.vault.recoverPendingICloudRestoreSettings(
                applySettings: { applied = $0 },
                beforeJournalClear: { throw TestFailure.injected }
            )
        )
        XCTAssertThrowsError(
            try destination.vault.authorizeAgentCredential(
                named: "Restored",
                operation: .read,
                caller: .init(name: "clear-failure")
            )
        ) { error in
            guard case VaultError.agentAccessPaused = error else {
                return XCTFail("Expected journal clear failure to stay paused, got \(error)")
            }
        }
        applied = nil

        _ = try VaultICloudBackupRestoreTarget(
            vault: destination.vault,
            currentSettings: { currentSettings },
            applySettings: { applied = $0 }
        )

        XCTAssertEqual(applied, restoredSettings)
        XCTAssertEqual(
            try destination.vault.authorizeAgentCredential(
                named: "Restored",
                operation: .read,
                caller: .init(name: "after-recovery")
            ),
            .requiresApproval
        )
    }

    func testRestoreRejectsAnInvalidBundleBeforeReplacingTheExistingLibrary() throws {
        let destination = try makeVault()
        try destination.vault.beginManagementSession(using: .allow)
        _ = try destination.vault.createTextCredential(
            .init(name: "Before", value: "unchanged"),
            using: .allow
        )
        let invalidComponents = [
            CredentialComponentInput(
                name: "CERTIFICATE",
                value: .file(filename: "", bytes: Data("x".utf8))
            )
        ]
        let invalidSnapshot = ICloudBackupSnapshot(
            credentials: [
                ICloudBackupCredential(
                    id: "invalid-bundle",
                    displayName: "Imported Bundle",
                    payload: .bundle(try JSONEncoder().encode(invalidComponents)),
                    permission: .allowed
                )
            ],
            groupNames: [],
            settings: snapshot("current").settings
        )

        XCTAssertThrowsError(
            try destination.vault.restoreLibraryFromICloudBackup(
                invalidSnapshot,
                currentSettings: { self.snapshot("current").settings },
                persistLocalSafetySnapshot: { _ in },
                applySettings: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? ICloudBackupError, .invalidSnapshot)
        }
        XCTAssertEqual(try destination.vault.listTextCredentials().map(\.name), ["Before"])
    }

    func testMissingEntitlementContainerFailsClosedWithoutTouchingKeychain() throws {
        XCTAssertThrowsError(try ICloudFileBackupStore(provider: TestContainerProvider(url: nil))) { error in
            XCTAssertEqual(error as? ICloudBackupError, .containerUnavailable)
        }
    }

    func testFileStoreUsesOnlyOpaqueBackupPathsAndCreateIsImmutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyICloudBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ICloudFileBackupStore(provider: TestContainerProvider(url: root))
        let path = "askkey-backup/key-id/generations/generation-id/blob"

        try store.create(Data("ciphertext".utf8), at: path)

        XCTAssertEqual(try store.read(at: path), Data("ciphertext".utf8))
        XCTAssertThrowsError(try store.create(Data(), at: path)) { error in
            XCTAssertEqual(error as? ICloudBackupStoreError, .alreadyExists)
        }
        XCTAssertThrowsError(try store.read(at: "../credential-name"))
    }

    func testFileStoreResolvesStandaloneConflictCopyAfterHumanSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyICloudConflictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try ICloudFileBackupStore(provider: TestContainerProvider(url: root))
        let conflictPath = "askkey-backup/key-id/generations/generation-id/blob (conflicted copy)"
        try store.create(Data("ciphertext".utf8), at: conflictPath)

        XCTAssertEqual(try store.conflictPaths(prefix: "askkey-backup/key-id"), [conflictPath])
        try store.resolveConflicts(prefix: "askkey-backup/key-id")
        XCTAssertTrue(try store.conflictPaths(prefix: "askkey-backup/key-id").isEmpty)
        XCTAssertNil(try store.read(at: conflictPath))
    }

    func testLocalStagingUploadAndCleanupFailuresAreObservable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyICloudStageTests-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        addTeardownBlock {
            _ = documents.path.withCString { Darwin.chmod($0, S_IRWXU) }
            try? FileManager.default.removeItem(at: root)
        }
        let path = "askkey-backup/key-id/generations/generation-id/blob"

        XCTAssertEqual(documents.path.withCString { Darwin.chmod($0, S_IRUSR | S_IXUSR) }, 0)
        let uploadStore = try ICloudFileBackupStore(provider: TestContainerProvider(url: root))
        XCTAssertThrowsError(try uploadStore.create(Data("ciphertext".utf8), at: path))
        XCTAssertEqual(documents.path.withCString { Darwin.chmod($0, S_IRWXU) }, 0)

        let cleanupManager = CleanupFailingFileManager()
        let cleanupStore = try ICloudFileBackupStore(
            provider: TestContainerProvider(url: root),
            fileManager: cleanupManager
        )
        XCTAssertThrowsError(try cleanupStore.create(Data("ciphertext".utf8), at: path))
        XCTAssertEqual(try cleanupStore.read(at: path), Data("ciphertext".utf8))
    }

    private var pendingUploadDirectory: URL?

    private func makePendingUploadDirectory() throws -> URL {
        if let pendingUploadDirectory { return pendingUploadDirectory }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupPendingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        pendingUploadDirectory = directory
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeBackup(store: MemoryBackupStore) throws -> ICloudBackupCoordinator {
        try ICloudBackupCoordinator(
            store: store,
            recoveryKey: BackupRecoveryKey.generate(),
            writerID: writerA,
            stateStore: MemoryBackupStateStore()
        )
    }

    private var writerA: String { "11111111-1111-4111-8111-111111111111" }
    private var writerB: String { "22222222-2222-4222-8222-222222222222" }

    private func snapshot(_ value: String) -> ICloudBackupSnapshot {
        ICloudBackupSnapshot(
            credentials: [
                ICloudBackupCredential(
                    id: "credential-id",
                    displayName: "Production API Key",
                    payload: .text(value),
                    usageInstructions: "Use for production",
                    privateNotes: "private",
                    groupName: "Production",
                    environmentVariable: "API_KEY",
                    permission: .allowed
                )
            ],
            groupNames: ["Production"],
            settings: .init(
                languageMode: "system",
                appearanceMode: "system",
                defaultTimedAllowanceMinutes: 30,
                launchAtLogin: true
            )
        )
    }

    private func makeVault() throws -> (vault: Vault, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (
            Vault(store: try VaultStore(path: directory.appendingPathComponent("vault.db").path), key: SymmetricKey(size: .bits256)),
            directory
        )
    }

    private func makeTakeoverFixture() throws -> (
        store: MemoryBackupStore,
        state: MemoryBackupStateStore,
        coordinator: ICloudBackupCoordinator,
        selected: ICloudBackupGeneration
    ) {
        let key = try BackupRecoveryKey.generate()
        let store = MemoryBackupStore()
        let source = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerA,
            stateStore: MemoryBackupStateStore()
        )
        _ = try source.backUp(snapshot: snapshot("first"))
        let selected = try source.backUp(snapshot: snapshot("second"))
        let state = MemoryBackupStateStore()
        let coordinator = try ICloudBackupCoordinator(
            store: store,
            recoveryKey: key,
            writerID: writerB,
            stateStore: state
        )
        XCTAssertThrowsError(try coordinator.backUp(snapshot: snapshot("blocked")))
        return (store, state, coordinator, selected)
    }
}

private final class MemoryBackupStore: ICloudBackupStore {
    private var files: [String: Data] = [:]
    var conflicts: [String] = []
    var failNextCurrentReplacement = false
    var failNextCreateSuffix: String?
    var failNextReplaceSuffix: String?
    var failNextDelete = false
    var collisionSuffix: String?
    var corruptNextCreateSuffix: String?
    let collisionData = Data("pre-existing immutable object".utf8)
    var blockNextBlobCreate = false
    let blobCreateStarted = DispatchSemaphore(value: 0)
    let allowBlobCreate = DispatchSemaphore(value: 0)
    var hideManifestList = false
    var hiddenManifestGenerationID: String?
    var failListing = false
    var paths: [String] { Array(files.keys) }
    var allData: [Data] { Array(files.values) }
    var generationIDs: [String] {
        paths.compactMap { path in
            guard path.hasSuffix("/manifest.json") else { return nil }
            return path.split(separator: "/").dropLast().last.map(String.init)
        }.sorted()
    }

    func create(_ data: Data, at path: String) throws {
        if blockNextBlobCreate, path.hasSuffix("/blob") {
            blockNextBlobCreate = false
            blobCreateStarted.signal()
            allowBlobCreate.wait()
        }
        if let suffix = collisionSuffix, path.hasSuffix(suffix) {
            collisionSuffix = nil
            files[path] = collisionData
            throw ICloudBackupStoreError.alreadyExists
        }
        if let suffix = failNextCreateSuffix, path.hasSuffix(suffix) {
            failNextCreateSuffix = nil
            throw TestFailure.injected
        }
        guard files[path] == nil else { throw ICloudBackupStoreError.alreadyExists }
        files[path] = data
        if let suffix = corruptNextCreateSuffix, path.hasSuffix(suffix), !data.isEmpty {
            corruptNextCreateSuffix = nil
            files[path]?[0] ^= 0xff
        }
    }

    func replace(_ data: Data, at path: String) throws {
        if let suffix = failNextReplaceSuffix, path.hasSuffix(suffix) {
            failNextReplaceSuffix = nil
            throw TestFailure.injected
        }
        if failNextCurrentReplacement, path.hasSuffix("/current.json") {
            failNextCurrentReplacement = false
            throw TestFailure.injected
        }
        files[path] = data
    }
    func read(at path: String) throws -> Data? { files[path] }
    func list(prefix: String) throws -> [String] {
        if failListing { throw TestFailure.injected }
        if hideManifestList { return [] }
        return paths.filter { path in
            guard path.hasPrefix(prefix) else { return false }
            if let hiddenManifestGenerationID,
               generationID(in: path) == hiddenManifestGenerationID {
                return false
            }
            return true
        }
    }
    func conflictPaths(prefix: String) throws -> [String] { conflicts }
    func resolveConflicts(prefix: String) throws { conflicts = [] }
    func delete(at path: String) throws {
        if failNextDelete {
            failNextDelete = false
            throw TestFailure.injected
        }
        files.removeValue(forKey: path)
    }

    func mutate(pathSuffix: String, mutation: (inout Data) -> Void) throws {
        let path = try XCTUnwrap(paths.first(where: { $0.hasSuffix(pathSuffix) }))
        var data = try XCTUnwrap(files[path])
        mutation(&data)
        files[path] = data
    }

    func mutateJSON(pathSuffix: String, mutation: (inout [String: Any]) -> Void) throws {
        try mutate(pathSuffix: pathSuffix) { data in
            var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            mutation(&object)
            data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        }
    }

    func setHint(named name: String, generationID: String) throws {
        let currentPath = try XCTUnwrap(paths.first(where: { $0.hasSuffix("/current.json") }))
        let path = currentPath.replacingOccurrences(of: "/current.json", with: "/\(name).json")
        files[path] = try JSONSerialization.data(withJSONObject: ["generationID": generationID], options: [.sortedKeys])
    }

    func removeHint(named name: String) throws {
        let currentPath = try XCTUnwrap(paths.first(where: { $0.hasSuffix("/current.json") }))
        files.removeValue(forKey: currentPath.replacingOccurrences(of: "/current.json", with: "/\(name).json"))
    }

    private func generationID(in path: String) -> String? {
        guard path.hasSuffix("/manifest.json") else { return nil }
        return path.split(separator: "/").dropLast().last.map(String.init)
    }

    func clone() -> MemoryBackupStore {
        let copy = MemoryBackupStore()
        copy.files = files
        return copy
    }

    func mergeGenerationObjects(from other: MemoryBackupStore) {
        for (path, data) in other.files where path.contains("/generations/") {
            files[path] = data
        }
    }
}

private enum TestFailure: Error { case injected }

private final class AsyncResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.result = result
    }

    func get() throws -> Result<Value, Error> {
        lock.lock(); defer { lock.unlock() }
        return try XCTUnwrap(result)
    }
}

private final class MemoryBackupStateStore: ICloudBackupLocalStateStore {
    private let accessLock = NSLock()
    private var paused: [String: Bool] = [:]
    private var allBackupsStopped = false
    private var takeover: [String: String] = [:]
    private var cleanup: [String: [String]] = [:]
    private var pendingUploads: [String: Data] = [:]
    var failWrites = false
    var failNextWrite = false
    var failOnWriteNumber: Int?

    func beginExclusiveAccess(namespace: String) { accessLock.lock() }
    func endExclusiveAccess(namespace: String) { accessLock.unlock() }

    func isAutomaticBackupPaused(namespace: String) throws -> Bool {
        allBackupsStopped || (paused[namespace] ?? false)
    }
    func setAutomaticBackupPaused(_ value: Bool, namespace: String) throws {
        try failIfRequested()
        paused[namespace] = value
    }
    func acceptedTakeoverGeneration(namespace: String) throws -> String? { takeover[namespace] }
    func setAcceptedTakeoverGeneration(_ generationID: String?, namespace: String) throws {
        try failIfRequested()
        takeover[namespace] = generationID
    }
    func pendingCleanupPaths(namespace: String) throws -> [String] { cleanup[namespace] ?? [] }
    func setPendingCleanupPaths(_ paths: [String], namespace: String) throws {
        try failIfRequested()
        cleanup[namespace] = paths
    }

    func pendingUpload(namespace: String) throws -> Data? { pendingUploads[namespace] }
    func setPendingUpload(_ data: Data?, namespace: String) throws {
        pendingUploads[namespace] = data
    }

    func stopAllAutomaticBackups() {
        accessLock.lock(); allBackupsStopped = true; accessLock.unlock()
    }

    func resumeAutomaticBackupsForNewInstallation() {
        accessLock.lock(); allBackupsStopped = false; accessLock.unlock()
    }

    private func failIfRequested() throws {
        if let remaining = failOnWriteNumber {
            if remaining == 1 {
                failOnWriteNumber = nil
                throw TestFailure.injected
            }
            failOnWriteNumber = remaining - 1
        }
        if failNextWrite {
            failNextWrite = false
            throw TestFailure.injected
        }
        if failWrites { throw TestFailure.injected }
    }
}

private enum TakeoverFailure: String, CaseIterable {
    case childClaimDelete
    case writer
    case previous
    case current
    case acceptedTakeover
    case automaticBackupResume
}

private final class MemoryBackupMaterialStore: ICloudBackupMaterialStore {
    private var values: [String: ICloudBackupKeyMaterial] = [:]
    var failNextDelete = false

    func save(_ material: ICloudBackupKeyMaterial) throws {
        values[material.recoveryKey.keyID] = material
    }

    func load(keyID: String) throws -> ICloudBackupKeyMaterial? { values[keyID] }
    func delete(keyID: String) throws {
        if failNextDelete {
            failNextDelete = false
            throw TestFailure.injected
        }
        values.removeValue(forKey: keyID)
    }
}

private final class RestoreTarget: ICloudBackupRestoreTarget {
    let safetySnapshot = Data("encrypted-local-safety-snapshot".utf8)
    var replacement: ICloudBackupSnapshot?

    func restoreLibraryAtomically(
        with snapshot: ICloudBackupSnapshot,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws {
        try persistLocalSafetySnapshot(safetySnapshot)
        replacement = snapshot
    }
}

private final class FailingRestoreTarget: ICloudBackupRestoreTarget {
    let safetySnapshot = Data("encrypted-safety".utf8)
    func restoreLibraryAtomically(
        with snapshot: ICloudBackupSnapshot,
        persistLocalSafetySnapshot: (Data) throws -> Void
    ) throws {
        try persistLocalSafetySnapshot(safetySnapshot)
        throw TestFailure.injected
    }
}

private struct TestContainerProvider: ICloudBackupContainerProviding {
    let url: URL?
    func containerURL() -> URL? { url }
}

private final class CleanupFailingFileManager: FileManager, @unchecked Sendable {
    private var shouldFail = true

    override func removeItem(at URL: URL) throws {
        if shouldFail, URL.lastPathComponent.hasPrefix("AskKeyBackupStage-") {
            shouldFail = false
            throw TestFailure.injected
        }
        try super.removeItem(at: URL)
    }
}
