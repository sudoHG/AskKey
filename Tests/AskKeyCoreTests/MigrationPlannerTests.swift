import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class MigrationPlannerTests: XCTestCase {
    func testAgentStartupCreatesFreshLibraryWithoutManagementSession() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = InMemoryMigrationKeyStore(legacyKey: Data(repeating: 0x11, count: 32))
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyDatabase.path))
    }

    func testAgentStartupLoadsCurrentLibraryWithoutManagementSessionAndIsIdempotent() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = InMemoryMigrationKeyStore(legacyKey: Data(repeating: 0x11, count: 32))
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

    func testAgentStartupRejectsLegacyWithoutRequestingAnyKey() throws {
        let fixture = try fixedLegacyFixture()
        let sourceBytes = try directoryBytes(fixture.directory)
        let placeholder = try VaultStore(path: try temporaryDirectory().appendingPathComponent("placeholder.db").path)
        defer { try? placeholder.close() }
        let vault = Vault(store: placeholder)
        XCTAssertThrowsError(try vault.prepareAgentRuntime(paths: .init(directory: fixture.directory), keyStore: {
            XCTFail("Legacy startup must stop before accessing any key")
            return InMemoryMigrationKeyStore(legacyKey: Data())
        })) { error in
            XCTAssertEqual(error as? VaultBootstrapError, .migrationRequired(.legacy))
        }
        XCTAssertTrue(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
        XCTAssertThrowsError(try vault.brokerCredentialCatalog(cancellation: .init()))
        XCTAssertEqual(try directoryBytes(fixture.directory), sourceBytes)
    }

    func testAgentStartupDoesNotRecoverPromotedButIncompleteMigration() throws {
        let fixture = try makeLegacyFixture([.init(name: "TOKEN", value: "synthetic", project: "Default")])
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = InMemoryMigrationKeyStore(legacyKey: VaultCrypto.keyToData(fixture.legacyKey))
        let committer = MigrationCommitter(legacyDatabaseURL: fixture.databaseURL, newDatabaseURL: paths.currentDatabase, journalURL: paths.currentJournal, keyStore: keys, afterStep: { state in
            if state == .dbPromoted { throw InjectedMigrationCrash() }
        })
        _ = try committer.prepare()
        XCTAssertThrowsError(try committer.commit())
        let journalBefore = try Data(contentsOf: paths.currentJournal)
        let pendingBefore = keys.pendingKey
        let placeholder = try VaultStore(path: try temporaryDirectory().appendingPathComponent("placeholder.db").path)
        defer { try? placeholder.close() }
        let vault = Vault(store: placeholder)
        XCTAssertThrowsError(try vault.prepareAgentRuntime(paths: paths, keyStore: { keys })) {
            XCTAssertEqual($0 as? VaultBootstrapError, .migrationRequired(.migrated))
        }
        XCTAssertNil(keys.appKey)
        XCTAssertEqual(keys.pendingKey, pendingBefore)
        XCTAssertNotNil(keys.legacyKey)
        XCTAssertEqual(try Data(contentsOf: paths.currentJournal), journalBefore)
        XCTAssertTrue(vault.isLocked)
        XCTAssertFalse(vault.hasActiveManagementSession)
    }

    func testBootstrapFourStatesAndLegacyInspectionDoesNotWriteSource() throws {
        let fresh = VaultBootstrapPaths(directory: try temporaryDirectory())
        XCTAssertEqual(try VaultBootstrap.state(paths: fresh), .fresh)
        let fixture = try fixedLegacyFixture()
        let paths = VaultBootstrapPaths(directory: fixture.directory)
        let before = try directoryBytes(fixture.directory)
        XCTAssertEqual(try VaultBootstrap.state(paths: paths), .legacy)
        XCTAssertEqual(try directoryBytes(fixture.directory), before)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: InMemoryMigrationKeyStore(legacyKey: VaultCrypto.keyToData(fixture.legacyKey))))
        XCTAssertEqual(try directoryBytes(fixture.directory), before)
        try FileManager.default.copyItem(at: paths.legacyDatabase, to: paths.previousDatabase)
        XCTAssertEqual(try VaultBootstrap.state(paths: paths), .mixed)
        try FileManager.default.copyItem(at: paths.previousDatabase, to: paths.currentDatabase)
        XCTAssertEqual(try VaultBootstrap.state(paths: paths), .migrated)
    }

    func testFreshBootstrapResumesPendingKeyButNeverReplacesActivatedMissingDatabase() throws {
        let paths = VaultBootstrapPaths(directory: try temporaryDirectory())
        let keys = InMemoryMigrationKeyStore(legacyKey: Data(repeating: 1, count: 32))
        keys.pendingKey = Data(repeating: 0x42, count: 32)
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        XCTAssertEqual(VaultCrypto.keyToData(opened.key), Data(repeating: 0x42, count: 32))
        XCTAssertEqual(keys.appKey, Data(repeating: 0x42, count: 32))
        XCTAssertNil(keys.pendingKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.legacyDatabase.path))
        try opened.store.close()
        try FileManager.default.removeItem(at: paths.currentDatabase)
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
            XCTAssertEqual($0 as? VaultBootstrapError, .missingDatabase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.currentDatabase.path))
        XCTAssertEqual(keys.appKey, Data(repeating: 0x42, count: 32))
    }

    func testAcceptedPreviewFingerprintRejectsLaterSourceChanges() throws {
        let fixture = try makeLegacyFixture([.init(name: "TOKEN", value: "synthetic", project: "Default")])
        let preview = try planner(for: fixture).preview()
        let source = try VaultStore(path: fixture.databaseURL.path)
        try source.setConfigValue(key: "changed_after_user_review", value: "yes")
        try source.close()
        let target = try temporaryDirectory()
        let keys = InMemoryMigrationKeyStore(legacyKey: VaultCrypto.keyToData(fixture.legacyKey))
        let committer = MigrationCommitter(legacyDatabaseURL: fixture.databaseURL, newDatabaseURL: target.appendingPathComponent("credentials-v2.db"), journalURL: target.appendingPathComponent("migration-v2.journal"), keyStore: keys)
        XCTAssertThrowsError(try committer.prepare(expectedSourceFingerprint: XCTUnwrap(preview.sourceFingerprint))) {
            XCTAssertEqual($0 as? MigrationCommitError, .legacyVaultChanged)
        }
        XCTAssertNil(keys.appKey)
        XCTAssertNotNil(keys.legacyKey)
    }

    func testMixedLegacyAndRecycledCredentialMigrateWithoutDroppingFields() throws {
        let fixture = try makeLegacyFixture([.init(name: "LEGACY", value: "old-synthetic", project: "Default")])
        let source = try VaultStore(path: fixture.databaseURL.path)
        let key = fixture.legacyKey
        // Match the persisted runtime format from sharedDateFormatter (whole
        // seconds); Foundation's default ISO8601 parser rejects fractions.
        let now = "2026-09-05T10:00:00Z"
        let encrypt: (String) throws -> Data = { try VaultCrypto.encrypt($0, using: key) }
        let record = CredentialRecord(id: "recycled-modern", nameIndex: Data(repeating: 0x11, count: 32), encryptedDisplayName: try encrypt("RECYCLED"), encryptedPayload: try encrypt("new-synthetic"), encryptedUsageInstructions: try encrypt("usage"), encryptedPrivateNotes: try encrypt("private"), encryptedGroupName: try encrypt("Group"), encryptedEnvironmentVariable: try encrypt("RECYCLED_TOKEN"), payloadKind: "text", permission: "allowed", expiresAt: "2030-01-01T00:00:00Z", createdAt: now, updatedAt: now, encryptedOriginalFilename: nil, byteSize: nil, contentDigest: nil, deletedAt: now)
        try source.db.write { try record.insert($0) }
        let groups = try VaultCrypto.encrypt(JSONEncoder().encode(["Empty Group", "Group"]), using: key)
        try source.setConfigValue(key: "credential_groups", value: groups.base64EncodedString())
        try source.close()
        let sourceBytes = try directoryBytes(fixture.directory)
        XCTAssertEqual(try VaultBootstrap.state(paths: .init(directory: fixture.directory)), .mixed)
        let preview = try planner(for: fixture).preview()
        XCTAssertEqual(preview.proposals.count, 2)
        XCTAssertTrue(preview.requiresAuthorizationReview)
        XCTAssertTrue(preview.proposals.allSatisfy { $0.permission == .ask })
        let target = try temporaryDirectory()
        let paths = VaultBootstrapPaths(directory: target)
        let keys = InMemoryMigrationKeyStore(legacyKey: VaultCrypto.keyToData(key))
        let committer = MigrationCommitter(legacyDatabaseURL: fixture.databaseURL, newDatabaseURL: paths.currentDatabase, journalURL: paths.currentJournal, keyStore: keys)
        _ = try committer.prepare(expectedSourceFingerprint: XCTUnwrap(preview.sourceFingerprint))
        try committer.commit()
        let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
        defer { try? opened.store.close() }
        XCTAssertEqual(try opened.store.fetchAllCredentials().count, 1)
        XCTAssertEqual(try VaultBootstrap.credentialCount(paths: paths), 2)
        let migrated = try XCTUnwrap(opened.store.fetchRecycledCredentials().first)
        XCTAssertEqual(migrated.id, record.id)
        XCTAssertEqual(migrated.deletedAt, now)
        XCTAssertEqual(migrated.createdAt, now)
        XCTAssertEqual(migrated.expiresAt, record.expiresAt)
        XCTAssertEqual(migrated.permission, "ask")
        XCTAssertEqual(try VaultCrypto.decrypt(migrated.encryptedPayload, using: opened.key), "new-synthetic")
        XCTAssertEqual(try VaultCrypto.decrypt(migrated.encryptedPrivateNotes, using: opened.key), "private")
        XCTAssertEqual(try VaultCrypto.decrypt(XCTUnwrap(migrated.encryptedEnvironmentVariable), using: opened.key), "RECYCLED_TOKEN")
        XCTAssertNotEqual(migrated.encryptedPayload, record.encryptedPayload)
        XCTAssertNotNil(migrated.authenticationTag)
        let migratedGroups = try XCTUnwrap(opened.store.configValue(key: "credential_groups"))
        let groupData = try VaultCrypto.decryptData(XCTUnwrap(Data(base64Encoded: migratedGroups)), using: opened.key)
        XCTAssertTrue(try JSONDecoder().decode([String].self, from: groupData).contains("Empty Group"))
        XCTAssertEqual(try directoryBytes(fixture.directory), sourceBytes)
        try opened.store.db.write { try $0.execute(sql: "UPDATE credentials SET authentication_tag = NULL WHERE id = ?", arguments: [record.id]) }
        try opened.store.close()
        XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys))
    }

    func testPreparedMigrationCanRollBackWithoutChangingLegacyVaultOrKey() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "ROLLBACK", value: "still-legacy", project: "Default"),
        ])
        let migrationDirectory = try temporaryDirectory()
        let keyStore = InMemoryMigrationKeyStore(
            legacyKey: VaultCrypto.keyToData(fixture.legacyKey)
        )
        let committer = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: migrationDirectory.appendingPathComponent("credentials.db"),
            journalURL: migrationDirectory.appendingPathComponent("migration.journal"),
            keyStore: keyStore
        )
        let legacyBytes = try directoryBytes(fixture.directory)

        let preview = try committer.prepare()

        XCTAssertTrue(preview.canCommit)
        XCTAssertEqual(try committer.state(), .prepared)
        XCTAssertEqual(try directoryBytes(fixture.directory), legacyBytes)
        XCTAssertEqual(keyStore.legacyKey, VaultCrypto.keyToData(fixture.legacyKey))

        try committer.rollbackPrepared()

        XCTAssertNil(try committer.state())
        XCTAssertEqual(try directoryBytes(fixture.directory), legacyBytes)
        XCTAssertEqual(keyStore.legacyKey, VaultCrypto.keyToData(fixture.legacyKey))
        XCTAssertNil(keyStore.pendingKey)
        XCTAssertNil(keyStore.appKey)
    }

    func testRollbackCrashAfterJournalRemovalLeavesLegacyUsableAndRetryable() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "ROLLBACK_CRASH", value: "still-legacy", project: "Default"),
        ])
        let migrationDirectory = try temporaryDirectory()
        let newDatabaseURL = migrationDirectory.appendingPathComponent("credentials.db")
        let journalURL = migrationDirectory.appendingPathComponent("migration.journal")
        let keyStore = InMemoryMigrationKeyStore(
            legacyKey: VaultCrypto.keyToData(fixture.legacyKey)
        )
        let legacyBytes = try directoryBytes(fixture.directory)
        let prepared = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: newDatabaseURL,
            journalURL: journalURL,
            keyStore: keyStore
        )
        _ = try prepared.prepare()
        let interrupted = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: newDatabaseURL,
            journalURL: journalURL,
            keyStore: keyStore,
            afterRollbackJournalRemoved: { throw InjectedMigrationCrash() }
        )

        XCTAssertThrowsError(try interrupted.rollbackPrepared()) { error in
            XCTAssertTrue(error is InjectedMigrationCrash)
        }
        XCTAssertNil(try interrupted.state())
        XCTAssertEqual(try directoryBytes(fixture.directory), legacyBytes)
        XCTAssertEqual(keyStore.legacyKey, VaultCrypto.keyToData(fixture.legacyKey))
        XCTAssertNotNil(keyStore.pendingKey)

        let retry = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: newDatabaseURL,
            journalURL: journalURL,
            keyStore: keyStore
        )
        XCTAssertTrue(try retry.prepare().canCommit)
        XCTAssertEqual(try retry.state(), .prepared)
    }

    func testPrepareCleansCrashOrphansBeforeCreatingANewJournal() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "ORPHAN", value: "recoverable", project: "Default"),
        ])
        let migrationDirectory = try temporaryDirectory()
        let newDatabaseURL = migrationDirectory.appendingPathComponent("credentials.db")
        let orphanURL = newDatabaseURL.appendingPathExtension("pending")
        try Data("abandoned staging database".utf8).write(to: orphanURL)
        let keyStore = InMemoryMigrationKeyStore(
            legacyKey: VaultCrypto.keyToData(fixture.legacyKey)
        )
        keyStore.pendingKey = Data(repeating: 0x44, count: 32)
        let committer = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: newDatabaseURL,
            journalURL: migrationDirectory.appendingPathComponent("migration.journal"),
            keyStore: keyStore
        )

        let preview = try committer.prepare()

        XCTAssertTrue(preview.canCommit)
        XCTAssertEqual(try committer.state(), .prepared)
        XCTAssertNotEqual(keyStore.pendingKey, Data(repeating: 0x44, count: 32))
    }

    func testLegacyWriteBetweenPreviewAndPreparationFailsClosed() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "RACE", value: "before", project: "Default"),
        ])
        let migrationDirectory = try temporaryDirectory()
        let committer = MigrationCommitter(
            legacyDatabaseURL: fixture.databaseURL,
            newDatabaseURL: migrationDirectory.appendingPathComponent("credentials.db"),
            journalURL: migrationDirectory.appendingPathComponent("migration.journal"),
            keyStore: InMemoryMigrationKeyStore(
                legacyKey: VaultCrypto.keyToData(fixture.legacyKey)
            ),
            afterPreview: {
                try VaultStore(path: fixture.databaseURL.path)
                    .setConfigValue(key: "raced", value: "yes")
            }
        )

        XCTAssertThrowsError(try committer.prepare()) { error in
            XCTAssertEqual(error as? MigrationCommitError, .legacyVaultChanged)
        }
        XCTAssertNil(try committer.state())
    }

    func testQuiescedLegacyStoreAllowsReadsButRejectsEveryWrite() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "QUIESCE", value: "unchanged", project: "Default"),
        ])
        let store = try VaultStore(path: fixture.databaseURL.path)
        let projectCount = try store.fetchAllProjects().count

        let quiescedStore = try store.quiescedCopy()

        XCTAssertEqual(try quiescedStore.fetchAllProjects().count, projectCount)
        XCTAssertThrowsError(
            try quiescedStore.setConfigValue(key: "must_not_write", value: "blocked")
        )
    }

    func testClosingLegacyStoreDrainsInFlightWriteAndRejectsFutureWrites() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "DRAIN", value: "unchanged", project: "Default"),
        ])
        let store = try VaultStore(path: fixture.databaseURL.path)
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeFinished = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        let worker = DispatchQueue(label: "AskKeyMigrationDrainTest", attributes: .concurrent)

        worker.async {
            defer { writeFinished.signal() }
            do {
                try store.db.write { database in
                    writeStarted.signal()
                    releaseWrite.wait()
                    try database.execute(
                        sql: "INSERT OR REPLACE INTO config (key, value) VALUES ('drained', 'yes')"
                    )
                }
            } catch {
                XCTFail("in-flight write failed before the drain barrier: \(error)")
            }
        }
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        worker.async {
            do {
                try store.close()
            } catch {
                XCTFail("legacy store close failed: \(error)")
            }
            closeFinished.signal()
        }

        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.1), .timedOut)
        releaseWrite.signal()
        XCTAssertEqual(writeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 2), .success)
        XCTAssertThrowsError(
            try store.setConfigValue(key: "after_close", value: "blocked")
        )
    }

    func testEveryCommitCrashPointRecoversForwardAndRevokesOldKeyLast() throws {
        for crashPoint in [
            MigrationJournalState.dbPromoted,
            .keyPromoted,
            .oldRevoked,
            .complete,
        ] {
            let fixture = try makeLegacyFixture([
                .init(
                    name: "RECOVER_\(crashPoint.rawValue)",
                    value: "value-\(crashPoint.rawValue)",
                    access: .strict,
                    project: "Recovery"
                ),
            ])
            let migrationDirectory = try temporaryDirectory()
            let newDatabaseURL = migrationDirectory.appendingPathComponent("credentials.db")
            let journalURL = migrationDirectory.appendingPathComponent("migration.journal")
            let keyStore = InMemoryMigrationKeyStore(
                legacyKey: VaultCrypto.keyToData(fixture.legacyKey)
            )
            var observedSteps: [MigrationJournalState] = []
            let interrupted = MigrationCommitter(
                legacyDatabaseURL: fixture.databaseURL,
                newDatabaseURL: newDatabaseURL,
                journalURL: journalURL,
                keyStore: keyStore,
                afterStep: { completedStep in
                    observedSteps.append(completedStep)
                    if completedStep == crashPoint { throw InjectedMigrationCrash() }
                }
            )
            _ = try interrupted.prepare()

            XCTAssertThrowsError(try interrupted.commit()) { error in
                XCTAssertTrue(error is InjectedMigrationCrash)
            }
            if crashPoint == .dbPromoted {
                XCTAssertThrowsError(try interrupted.rollbackPrepared()) { error in
                    XCTAssertEqual(
                        error as? MigrationCommitError,
                        .rollbackNotAllowed(.dbPromoted)
                    )
                }
            }
            if crashPoint != .oldRevoked && crashPoint != .complete {
                XCTAssertNotNil(keyStore.legacyKey, "old key was revoked before \(crashPoint)")
            }

            let recovery = MigrationCommitter(
                legacyDatabaseURL: fixture.databaseURL,
                newDatabaseURL: newDatabaseURL,
                journalURL: journalURL,
                keyStore: keyStore
            )
            try recovery.recover()

            XCTAssertEqual(try recovery.state(), .complete)
            XCTAssertNil(keyStore.legacyKey)
            XCTAssertNil(keyStore.pendingKey)
            let appKeyData = try XCTUnwrap(keyStore.appKey)
            let migratedStore = try VaultStore(path: newDatabaseURL.path)
            migratedStore.bindCredentialAuthenticationKey(VaultCrypto.keyFromData(appKeyData))
            let records = try migratedStore.fetchAllCredentials()
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(record.permission, CredentialPermission.ask.rawValue)
            XCTAssertEqual(
                try VaultCrypto.decrypt(
                    record.encryptedDisplayName,
                    using: VaultCrypto.keyFromData(appKeyData)
                ),
                "RECOVER_\(crashPoint.rawValue)"
            )
            XCTAssertEqual(
                try VaultCrypto.decrypt(
                    record.encryptedPayload,
                    using: VaultCrypto.keyFromData(appKeyData)
                ),
                "value-\(crashPoint.rawValue)"
            )
            let databaseBytes = try Data(contentsOf: newDatabaseURL)
            XCTAssertFalse(databaseBytes.contains(Data("value-\(crashPoint.rawValue)".utf8)))
            XCTAssertEqual(observedSteps.last, crashPoint)
        }
    }

    func testLegacyTextPermissionProjectAndEnvironmentBecomeEncryptedVNextPreview() throws {
        let fixture = try fixedLegacyFixture()
        let migrationKey = SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        let legacyBytesBefore = try directoryBytes(fixture.directory)
        let legacyKeyBefore = VaultCrypto.keyToData(fixture.legacyKey)

        let preview = try MigrationPlanner(
            databaseURL: fixture.databaseURL,
            legacyKey: fixture.legacyKey,
            migrationKey: migrationKey
        ).preview()

        XCTAssertEqual(preview.statistics, .init(credentials: 1, conflicts: 0))
        XCTAssertTrue(preview.canCommit)
        let proposal = try XCTUnwrap(preview.proposals.first)
        XCTAssertEqual(proposal.displayName, "OpenAI Key")
        XCTAssertEqual(proposal.permission, .ask)
        XCTAssertEqual(proposal.source.projectName, "Client App")
        XCTAssertEqual(proposal.source.environmentName, "Production")
        XCTAssertEqual(proposal.suggestedGroupName, "Client App")
        XCTAssertFalse(proposal.stagedCredential.encryptedDisplayName.contains(Data("OpenAI Key".utf8)))
        XCTAssertFalse(proposal.stagedCredential.encryptedPayload.contains(Data("sk-fixture".utf8)))
        XCTAssertEqual(proposal.stagedCredential.nameIndex.count, 32)
        XCTAssertEqual(
            try VaultCrypto.decrypt(proposal.stagedCredential.encryptedDisplayName, using: migrationKey),
            "OpenAI Key"
        )
        XCTAssertEqual(
            try VaultCrypto.decrypt(proposal.stagedCredential.encryptedPayload, using: migrationKey),
            "sk-fixture"
        )
        XCTAssertEqual(try directoryBytes(fixture.directory), legacyBytesBefore)
        XCTAssertEqual(VaultCrypto.keyToData(fixture.legacyKey), legacyKeyBefore)
    }

    func testUnauthenticatedLegacyPermissionsRequireExplicitReviewAndResetToAsk() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "ALLOWED", value: "a", access: .allowed, project: "One"),
            .init(name: "APPROVAL", value: "b", access: .requiresApproval, project: "Two"),
            .init(name: "STRICT", value: "c", access: .strict, project: "Three"),
            .init(name: "BLOCKED", value: "d", access: .blocked, project: "Four"),
        ])

        let preview = try planner(for: fixture).preview()
        XCTAssertTrue(preview.requiresAuthorizationReview)
        let permissions = Dictionary(uniqueKeysWithValues: preview
            .proposals.map { ($0.displayName, $0.permission) })

        XCTAssertEqual(permissions, [
            "ALLOWED": .ask,
            "APPROVAL": .ask,
            "STRICT": .ask,
            "BLOCKED": .ask,
        ])
        let originalPermissions = Dictionary(uniqueKeysWithValues: preview.proposals.map { ($0.displayName, $0.originalPermission) })
        XCTAssertEqual(originalPermissions["ALLOWED"] ?? nil, .allowed)
        XCTAssertEqual(originalPermissions["BLOCKED"] ?? nil, .hidden)
    }

    func testNormalizedNameCollisionIsListedAndBlocksCommit() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "Caf\u{00E9}", value: "first", project: "One"),
            .init(name: " cafe\u{0301} ", value: "second", project: "Two"),
        ])

        let preview = try planner(for: fixture).preview()

        XCTAssertFalse(preview.canCommit)
        XCTAssertEqual(preview.statistics, .init(credentials: 2, conflicts: 1))
        XCTAssertEqual(preview.conflicts.first?.displayNames, ["Caf\u{00E9}", "cafe\u{0301}"])
        XCTAssertEqual(preview.conflicts.first?.sources.map(\.projectName), ["One", "Two"])
    }

    func testCorruptDatabaseFailsWithoutChangingAnyLegacyBytes() throws {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("vault.db")
        try Data("not a sqlite database".utf8).write(to: databaseURL)
        let before = try directoryBytes(directory)

        XCTAssertThrowsError(
            try MigrationPlanner(
                databaseURL: databaseURL,
                legacyKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
                migrationKey: SymmetricKey(data: Data(repeating: 2, count: 32))
            ).preview()
        )

        XCTAssertEqual(try directoryBytes(directory), before)
    }

    func testUnknownLegacyFieldsAreIgnored() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "TOKEN", value: "known", project: "Default"),
        ], addUnknownField: true)

        let preview = try planner(for: fixture).preview()

        XCTAssertEqual(preview.proposals.map(\.displayName), ["TOKEN"])
    }

    func testDamagedEncryptedValueFailsWithoutChangingLegacyBytes() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "DAMAGED", value: "original", project: "Default"),
        ])
        do {
            let store = try VaultStore(path: fixture.databaseURL.path)
            try store.db.write { db in
                try db.execute(sql: "UPDATE secret_values SET encrypted_value = X'00'")
            }
        }
        let before = try directoryBytes(fixture.directory)

        XCTAssertThrowsError(try planner(for: fixture).preview())

        XCTAssertEqual(try directoryBytes(fixture.directory), before)
    }

    func testUnsupportedSchemaAndUnassociatedRecordsCannotProduceCommitReadyPreview() throws {
        let unsupported = try makeLegacyFixture([
            .init(name: "VERSIONED", value: "value", project: "Default"),
        ])
        do {
            let store = try VaultStore(path: unsupported.databaseURL.path)
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'")
            }
        }
        XCTAssertThrowsError(try planner(for: unsupported).preview()) { error in
            guard case MigrationPreviewError.invalidLegacyDatabase = error else {
                return XCTFail("Expected schema rejection, got \(error)")
            }
        }

        let incomplete = try makeLegacyFixture([
            .init(name: "ORPHANED", value: "value", project: "Default"),
        ])
        do {
            let store = try VaultStore(path: incomplete.databaseURL.path)
            try store.db.write { db in
                try db.execute(sql: "DELETE FROM secret_values")
            }
        }
        XCTAssertThrowsError(try planner(for: incomplete).preview()) { error in
            guard case MigrationPreviewError.invalidLegacyDatabase = error else {
                return XCTFail("Expected incomplete-record rejection, got \(error)")
            }
        }
    }

    func testMissingAndCrossProjectEnvironmentsCannotBeSilentlyDropped() throws {
        let missingEnvironment = try makeLegacyFixture([
            .init(name: "MISSING_ENV", value: "value", project: "Default"),
        ])
        do {
            let store = try VaultStore(path: missingEnvironment.databaseURL.path)
            try store.db.write { db in
                try db.execute(sql: "UPDATE secret_values SET environment_id = NULL")
            }
        }
        XCTAssertThrowsError(try planner(for: missingEnvironment).preview())

        let crossProject = try makeLegacyFixture([
            .init(name: "FIRST_PROJECT", value: "first", project: "One"),
            .init(name: "SECOND_PROJECT", value: "second", project: "Two"),
        ])
        do {
            let store = try VaultStore(path: crossProject.databaseURL.path)
            let firstProject = try XCTUnwrap(store.fetchProject(name: "One"))
            let secondProject = try XCTUnwrap(store.fetchProject(name: "Two"))
            let firstSecret = try XCTUnwrap(
                store.fetchSecret(name: "FIRST_PROJECT", projectId: firstProject.id)
            )
            let secondEnvironment = try XCTUnwrap(
                store.fetchEnvironment(name: "Default", projectId: secondProject.id)
            )
            try store.db.write { db in
                try db.execute(
                    sql: "UPDATE secret_values SET environment_id = ? WHERE secret_id = ?",
                    arguments: [secondEnvironment.id, firstSecret.id]
                )
            }
        }
        XCTAssertThrowsError(try planner(for: crossProject).preview())
    }

    func testInjectedMidPreviewFailureAndCancellationLeaveLegacyBytesUnchanged() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "FIRST", value: "one", project: "Default"),
            .init(name: "SECOND", value: "two", project: "Default"),
        ])
        let before = try directoryBytes(fixture.directory)
        let legacyKeyBefore = VaultCrypto.keyToData(fixture.legacyKey)
        let planner = planner(for: fixture)

        XCTAssertThrowsError(try planner.preview(failAfterCredentialCount: 1)) { error in
            XCTAssertEqual(error as? MigrationPreviewInjectedFailure, .init())
        }
        XCTAssertEqual(try directoryBytes(fixture.directory), before)
        XCTAssertEqual(VaultCrypto.keyToData(fixture.legacyKey), legacyKeyBefore)

        let cancellation = MigrationPreviewCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try planner.preview(cancellation: cancellation)) { error in
            XCTAssertEqual(error as? MigrationPreviewError, .cancelled)
        }
        XCTAssertEqual(try directoryBytes(fixture.directory), before)
        XCTAssertEqual(VaultCrypto.keyToData(fixture.legacyKey), legacyKeyBefore)
    }

    func testForcedProcessTerminationDuringPreviewLeavesLegacyBytesUnchanged() throws {
        let fixture = try makeLargeLegacyFixture(credentialCount: 5_000)
        let before = try directoryBytes(fixture.directory)
        let snapshotsBefore = try migrationSnapshotDirectories()
        let finishedURL = fixture.directory.appendingPathComponent("preview-finished")
        let startedURL = fixture.directory.appendingPathComponent("preview-started")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "AskKeyCoreTests.MigrationPlannerCrashHarnessTests/testTerminatesDuringActivePreview",
            Bundle(for: MigrationPlannerTests.self).bundleURL.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["ASKKEY_CRASH_DATABASE"] = fixture.databaseURL.path
        environment["ASKKEY_CRASH_FINISHED"] = finishedURL.path
        environment["ASKKEY_CRASH_STARTED"] = startedURL.path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path))
        let after = try directoryBytes(fixture.directory)
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), ["preview-started"])
        XCTAssertEqual(after.filter { before[$0.key] != nil }, before)
        XCTAssertThrowsError(try planner(for: fixture).preview(failAfterCredentialCount: 0))
        XCTAssertEqual(try migrationSnapshotDirectories(), snapshotsBefore)
    }

    func testWALWriteDuringSnapshotFailsClosedInsteadOfProducingMixedPreview() throws {
        let fixture = try makeLegacyFixture([
            .init(name: "CONCURRENT", value: "value", project: "Default"),
        ])
        let store = try VaultStore(path: fixture.databaseURL.path)

        XCTAssertThrowsError(try planner(for: fixture).preview(didCopyLegacyFiles: {
            try store.setConfigValue(key: "concurrent_preview_write", value: "observed")
        })) { error in
            guard case MigrationPreviewError.invalidLegacyDatabase(let message) = error else {
                return XCTFail("Expected concurrent-write rejection, got \(error)")
            }
            XCTAssertTrue(message.contains("changed"))
        }
    }
}

private struct InjectedMigrationCrash: Error {}

private final class InMemoryMigrationKeyStore: MigrationKeyStore {
    var legacyKey: Data?
    var pendingKey: Data?
    var appKey: Data?

    init(legacyKey: Data) {
        self.legacyKey = legacyKey
    }

    func loadLegacyKey() throws -> Data {
        guard let legacyKey else { throw MigrationKeyStoreError.missingLegacyKey }
        return legacyKey
    }

    func savePendingKey(_ data: Data) throws {
        if let pendingKey, pendingKey != data {
            throw MigrationKeyStoreError.conflictingKey
        }
        pendingKey = data
    }

    func loadPendingKey() throws -> Data {
        guard let pendingKey else { throw MigrationKeyStoreError.missingPendingKey }
        return pendingKey
    }

    func promotePendingKey() throws {
        appKey = try loadPendingKey()
    }

    func loadAppKey() throws -> Data {
        guard let appKey else { throw MigrationKeyStoreError.missingAppKey }
        return appKey
    }

    func deleteLegacyKey() throws { legacyKey = nil }
    func deletePendingKey() throws { pendingKey = nil }
    func deleteAppKey() throws { appKey = nil }
}

private extension MigrationPlannerTests {
    struct LegacySecret {
        let name: String
        let value: String
        let access: AgentAccessPolicy
        let project: String
        let environment: String

        init(
            name: String,
            value: String,
            access: AgentAccessPolicy = .allowed,
            project: String,
            environment: String = "Default"
        ) {
            self.name = name
            self.value = value
            self.access = access
            self.project = project
            self.environment = environment
        }
    }

    struct LegacyFixture {
        let directory: URL
        let databaseURL: URL
        let legacyKey: SymmetricKey
    }

    func makeLegacyFixture(
        _ secrets: [LegacySecret],
        addUnknownField: Bool = false
    ) throws -> LegacyFixture {
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("vault.db")
        let legacyKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))

        do {
            let store = try VaultStore(path: databaseURL.path)
            for secret in secrets {
                let project: ProjectRecord
                if let existing = try store.fetchProject(name: secret.project) {
                    project = existing
                } else {
                    let now = iso8601()
                    project = ProjectRecord(
                        id: UUID().uuidString,
                        name: secret.project,
                        activeEnvironment: secret.environment,
                        icon: nil,
                        createdAt: now,
                        updatedAt: now
                    )
                    try store.insertProject(project)
                }

                let environment: EnvironmentRecord
                if let existing = try store.fetchEnvironment(name: secret.environment, projectId: project.id) {
                    environment = existing
                } else {
                    environment = EnvironmentRecord(
                        id: UUID().uuidString,
                        projectId: project.id,
                        name: secret.environment,
                        color: nil,
                        createdAt: iso8601()
                    )
                    try store.insertEnvironment(environment)
                }

                let record = SecretRecord(
                    id: UUID().uuidString,
                    projectId: project.id,
                    name: secret.name,
                    description: "Legacy usage",
                    icon: nil,
                    category: SecretCategory.apiKey.rawValue,
                    createdAt: iso8601(),
                    updatedAt: iso8601(),
                    agentAccess: secret.access.rawValue
                )
                try store.insertSecret(record)
                try store.upsertSecretValue(.init(
                    id: UUID().uuidString,
                    secretId: record.id,
                    environmentId: environment.id,
                    encryptedValue: try VaultCrypto.encrypt(secret.value, using: legacyKey),
                    updatedAt: iso8601()
                ))
            }
            if addUnknownField {
                try store.db.write { db in
                    try db.execute(sql: "ALTER TABLE secrets ADD COLUMN future_payload BLOB")
                    try db.execute(sql: "UPDATE secrets SET future_payload = X'DEADBEEF'")
                }
            }
        }

        return .init(directory: directory, databaseURL: databaseURL, legacyKey: legacyKey)
    }

    func fixedLegacyFixture() throws -> LegacyFixture {
        let source = try XCTUnwrap(
            Bundle.module.url(
                forResource: "legacy-v7-vault",
                withExtension: "db",
                subdirectory: "Fixtures"
            )
        )
        let directory = try temporaryDirectory()
        let databaseURL = directory.appendingPathComponent("vault.db")
        try FileManager.default.copyItem(at: source, to: databaseURL)
        return .init(
            directory: directory,
            databaseURL: databaseURL,
            legacyKey: SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        )
    }

    func makeLargeLegacyFixture(credentialCount: Int) throws -> LegacyFixture {
        let fixture = try makeLegacyFixture([])
        let encrypted = try VaultCrypto.encrypt("bulk-value", using: fixture.legacyKey)
        let now = iso8601()
        do {
            let store = try VaultStore(path: fixture.databaseURL.path)
            let project = try XCTUnwrap(store.fetchProject(name: "Default"))
            let environment = try XCTUnwrap(
                store.fetchEnvironment(name: "Default", projectId: project.id)
            )
            try store.db.write { db in
                for index in 0..<credentialCount {
                    let secretID = "bulk-secret-\(index)"
                    try db.execute(sql: """
                        INSERT INTO secrets
                            (id, project_id, name, description, icon, category,
                             created_at, updated_at, agent_access)
                        VALUES (?, ?, ?, NULL, NULL, 'other', ?, ?, 'allowed')
                        """, arguments: [secretID, project.id, "BULK_\(index)", now, now])
                    try db.execute(sql: """
                        INSERT INTO secret_values
                            (id, secret_id, environment_id, encrypted_value, updated_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: ["bulk-value-\(index)", secretID, environment.id, encrypted, now])
                }
            }
        }
        return fixture
    }

    func planner(for fixture: LegacyFixture) -> MigrationPlanner {
        MigrationPlanner(
            databaseURL: fixture.databaseURL,
            legacyKey: fixture.legacyKey,
            migrationKey: SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        )
    }

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    func directoryBytes(_ directory: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        return try Dictionary(uniqueKeysWithValues: names.map { name in
            (name, try Data(contentsOf: directory.appendingPathComponent(name)))
        })
    }

    func migrationSnapshotDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix("AskKeyMigrationPreview-") }.sorted()
    }

}

final class MigrationPlannerCrashHarnessTests: XCTestCase {
    func testTerminatesDuringActivePreview() throws {
        guard let databasePath = ProcessInfo.processInfo.environment["ASKKEY_CRASH_DATABASE"],
              let finishedPath = ProcessInfo.processInfo.environment["ASKKEY_CRASH_FINISHED"],
              let startedPath = ProcessInfo.processInfo.environment["ASKKEY_CRASH_STARTED"] else {
            throw XCTSkip("Subprocess-only crash harness")
        }
        let planner = MigrationPlanner(
            databaseURL: URL(fileURLWithPath: databasePath),
            legacyKey: SymmetricKey(data: Data(repeating: 0x5A, count: 32)),
            migrationKey: SymmetricKey(data: Data(repeating: 0xA5, count: 32))
        )
        _ = try planner.preview { preparedCount in
            guard preparedCount == 1 else { return }
            _ = FileManager.default.createFile(atPath: startedPath, contents: Data())
            raise(SIGKILL)
        }
        _ = FileManager.default.createFile(atPath: finishedPath, contents: Data())
    }
}
