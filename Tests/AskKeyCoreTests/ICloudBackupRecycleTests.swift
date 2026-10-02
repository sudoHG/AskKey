import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import AskKeyCore

final class ICloudBackupRecycleTests: XCTestCase {
    private let settings = ICloudBackupSettings(
        languageMode: "system", appearanceMode: "system",
        defaultTimedAllowanceMinutes: 5, launchAtLogin: false
    )

    func testSnapshotRoundTripPreservesRecycledTextCredential() throws {
        let source = try makeVault()
        let destination = try makeVault()
        let active = try source.vault.createTextCredential(
            .init(name: "Active", value: "SYNTHETIC_ACTIVE", permission: .allowed),
            using: .allow
        )
        let recycled = try source.vault.createTextCredential(
            .init(name: "Recycled", value: "SYNTHETIC_RECYCLED", groupName: "Archive", permission: .hidden),
            using: .allow
        )
        try source.vault.deleteTextCredential(id: recycled.id, using: .allow)
        let originalDeletion = try XCTUnwrap(source.vault.listRecycledTextCredentials().first?.deletedAt)

        let snapshot = try source.vault.makeICloudBackupSnapshot(settings: settings)
        XCTAssertEqual(Set(snapshot.credentials.map(\.id)), Set([active.id, recycled.id]))
        let decoded = try JSONDecoder().decode(
            ICloudBackupSnapshot.self, from: JSONEncoder().encode(snapshot)
        )
        let target = try VaultICloudBackupRestoreTarget(
            vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        try target.restoreLibraryAtomically(with: decoded, persistLocalSafetySnapshot: { _ in })

        XCTAssertEqual(try destination.vault.listTextCredentials().map(\.id), [active.id])
        let restored = try XCTUnwrap(destination.vault.listRecycledTextCredentials().first)
        XCTAssertEqual(restored.id, recycled.id)
        XCTAssertEqual(restored.deletedAt, originalDeletion)
        XCTAssertEqual(restored.groupName, "Archive")
        XCTAssertEqual(restored.permission, .ask)
        try destination.vault.restoreRecycledTextCredential(id: restored.id, using: .allow)
        XCTAssertEqual(
            try destination.vault.revealTextCredential(id: restored.id, using: .allow).value,
            "SYNTHETIC_RECYCLED"
        )
    }

    func testRestoreRejectsDeletionTimeThatCannotRoundTripWithoutChangingIt() throws {
        let destination = try makeVault()
        let existing = try destination.vault.createTextCredential(
            .init(name: "Existing", value: "SYNTHETIC_EXISTING"), using: .allow
        )
        let target = try VaultICloudBackupRestoreTarget(
            vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        let cloud = try makeCloud()
        for seconds in [1_700_000_000.125, .nan, .infinity, -.infinity, 1e100] {
            let snapshot = ICloudBackupSnapshot(
                credentials: [.init(
                    id: "recycled", displayName: "Recycled", payload: .text("SYNTHETIC_RECYCLED"),
                    permission: .allowed, deletedAt: Date(timeIntervalSince1970: seconds)
                )], groupNames: [], settings: settings
            )
            XCTAssertThrowsError(try target.restoreLibraryAtomically(
                with: snapshot,
                persistLocalSafetySnapshot: { _ in XCTFail("Invalid deletion time must not begin replacement") }
            )) { XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot) }
            XCTAssertThrowsError(try cloud.coordinator.backUp(snapshot: snapshot)) {
                XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot)
            }
            XCTAssertEqual(try destination.vault.listTextCredentials().map(\.id), [existing.id])
            XCTAssertTrue(try destination.vault.listRecycledTextCredentials().isEmpty)
        }
        XCTAssertTrue(cloud.store.files.isEmpty)
    }

    func testCloudRoundTripPreservesActiveAndRecycledTextFileAndMixedCredentials() throws {
        let source = try makeVault()
        let destination = try makeVault()
        let cloud = try makeCloud()
        try source.vault.createCredentialGroup("Empty Group", using: .allow)
        var originals: [ManagedTextCredential] = []
        var recycledIDs = Set<String>()
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        for isRecycled in [false, true] {
            let prefix = isRecycled ? "Recycled" : "Active"
            let group = isRecycled ? "Only Recycled" : "Active Group"
            let text = try source.vault.createTextCredential(.init(
                name: "\(prefix) Text", value: "SYNTHETIC_TEXT", usageInstructions: "text usage",
                privateNotes: "text notes", groupName: group, environmentVariable: "TEXT_TOKEN",
                permission: .allowed, expiresAt: expiry
            ), using: .allow)
            let file = try source.vault.createFileCredential(.init(
                name: "\(prefix) File", snapshot: try FileImport.FrozenFile(
                    originalFilename: "fixture.pem", bytes: Data([0, 1, 2, 255])
                ), usageInstructions: "file usage", privateNotes: "file notes", groupName: group,
                environmentVariable: "CERT_PATH", permission: .hidden, expiresAt: expiry
            ), using: .allow)
            let mixed = try source.vault.createBundleCredential(.init(
                name: "\(prefix) Mixed", components: [
                    .init(name: "Token", value: .text("SYNTHETIC_MIXED"),
                          delivery: .environmentVariable("MIXED_TOKEN")),
                    .init(name: "Config", value: .file(filename: "fixture.json", bytes: Data("{}".utf8)),
                          delivery: .temporaryFile("CONFIG_PATH")),
                ], usageInstructions: "mixed usage", privateNotes: "mixed notes", groupName: group,
                permission: .allowed, expiresAt: expiry
            ), using: .allow)
            for credential in [text, file, mixed] {
                originals.append(try source.vault.revealTextCredential(id: credential.id, using: .allow))
                if isRecycled {
                    try source.vault.deleteTextCredential(id: credential.id, using: .allow)
                    recycledIDs.insert(credential.id)
                }
            }
        }
        let originalDeletionByID = try Dictionary(uniqueKeysWithValues:
            source.vault.listRecycledTextCredentials().map { ($0.id, try XCTUnwrap($0.deletedAt)) }
        )
        _ = try source.vault.backUpToICloud(using: cloud.coordinator, settings: settings)
        XCTAssertEqual(try cloud.coordinator.restoreSelection().snapshot.formatVersion, 2)
        let target = try VaultICloudBackupRestoreTarget(
            vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        try cloud.coordinator.restore(into: target, using: .allow, persistLocalSafetySnapshot: { _ in })

        XCTAssertEqual(Set(try destination.vault.listTextCredentials().map(\.id)),
                       Set(originals.map(\.id)).subtracting(recycledIDs))
        let recycled = try destination.vault.listRecycledTextCredentials()
        XCTAssertEqual(Set(recycled.map(\.id)), recycledIDs)
        for credential in recycled {
            XCTAssertEqual(credential.deletedAt, originalDeletionByID[credential.id])
            XCTAssertEqual(credential.permission, .ask)
        }
        XCTAssertEqual(try destination.vault.listCredentialGroups(), ["Active Group", "Empty Group", "Only Recycled"])
        for original in originals {
            if recycledIDs.contains(original.id) {
                XCTAssertThrowsError(try destination.vault.revealTextCredential(id: original.id, using: .allow))
                try destination.vault.restoreRecycledTextCredential(id: original.id, using: .allow)
            }
            let restored = try destination.vault.revealTextCredential(id: original.id, using: .allow)
            XCTAssertEqual(restored.permission, .ask)
            XCTAssertNil(restored.deletedAt)
            XCTAssertEqual(restored.name, original.name)
            XCTAssertEqual(restored.payloadKind, original.payloadKind)
            XCTAssertEqual(restored.value, original.value)
            XCTAssertEqual(restored.fileBytes, original.fileBytes)
            XCTAssertEqual(restored.originalFilename, original.originalFilename)
            XCTAssertEqual(restored.components, original.components)
            XCTAssertEqual(restored.environmentVariable, original.environmentVariable)
            XCTAssertEqual(restored.usageInstructions, original.usageInstructions)
            XCTAssertEqual(restored.privateNotes, original.privateNotes)
            XCTAssertEqual(restored.groupName, original.groupName)
            XCTAssertEqual(restored.expiresAt, original.expiresAt)
        }
    }

    func testSafetySnapshotCanRecoverRecycleBinAfterReplacementCommitFails() throws {
        let fixture = try makeVault()
        let active = try fixture.vault.createTextCredential(
            .init(name: "Before Active", value: "SYNTHETIC_ACTIVE"), using: .allow
        )
        let recycled = try fixture.vault.createTextCredential(
            .init(name: "Before Recycled", value: "SYNTHETIC_RECYCLED", groupName: "Recycle Group"), using: .allow
        )
        try fixture.vault.deleteTextCredential(id: recycled.id, using: .allow)
        let deletedAt = try XCTUnwrap(fixture.vault.listRecycledTextCredentials().first?.deletedAt)
        var safety: Data?
        enum Interrupted: Error { case afterCommit }
        XCTAssertThrowsError(try fixture.vault.restoreLibraryFromICloudBackup(
            ICloudBackupSnapshot(credentials: [], groupNames: [], settings: settings),
            currentSettings: { self.settings }, persistLocalSafetySnapshot: { safety = $0 },
            applySettings: { _ in }, afterDatabaseReplace: { throw Interrupted.afterCommit }
        )) { XCTAssertTrue($0 is Interrupted) }
        XCTAssertTrue(try fixture.vault.listTextCredentials().isEmpty)
        XCTAssertTrue(try fixture.vault.listRecycledTextCredentials().isEmpty)
        let encrypted = try XCTUnwrap(safety)
        XCTAssertNil(encrypted.range(of: Data("SYNTHETIC_RECYCLED".utf8)))
        let snapshot = try JSONDecoder().decode(
            ICloudBackupSnapshot.self, from: VaultCrypto.decryptData(encrypted, using: fixture.key)
        )
        try restore(snapshot, into: fixture.vault)
        XCTAssertEqual(try fixture.vault.listTextCredentials().map(\.id), [active.id])
        XCTAssertEqual(try fixture.vault.listRecycledTextCredentials().map(\.id), [recycled.id])
        XCTAssertEqual(try fixture.vault.listRecycledTextCredentials().first?.deletedAt, deletedAt)
        try fixture.vault.restoreRecycledTextCredential(id: recycled.id, using: .allow)
        let restored = try fixture.vault.revealTextCredential(id: recycled.id, using: .allow)
        XCTAssertEqual(restored.value, "SYNTHETIC_RECYCLED")
        XCTAssertEqual(restored.groupName, "Recycle Group")
        XCTAssertEqual(restored.permission, .ask)
    }

    func testLegacySnapshotWithoutDeletionTimeRestoresAsActiveThroughBothEntrypoints() throws {
        let payload = legacyPayload(version: 1)
        let snapshot = try JSONDecoder().decode(ICloudBackupSnapshot.self, from: payload)
        XCTAssertNil(try XCTUnwrap(snapshot.credentials.first).deletedAt)
        let direct = try makeVault()
        try restore(snapshot, into: direct.vault)
        XCTAssertEqual(try direct.vault.listTextCredentials().map(\.id), ["legacy"])
        XCTAssertTrue(try direct.vault.listRecycledTextCredentials().isEmpty)

        let cloud = try makeCloud()
        try installAuthenticatedPayload(payload, cloud: cloud)
        XCTAssertEqual(try cloud.coordinator.restoreSelection().snapshot.formatVersion, 1)
        let destination = try makeVault()
        let target = try VaultICloudBackupRestoreTarget(
            vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        try cloud.coordinator.restore(into: target, using: .allow, persistLocalSafetySnapshot: { _ in })
        let restored = try destination.vault.revealTextCredential(id: "legacy", using: .allow)
        XCTAssertEqual(restored.value, "SYNTHETIC_LEGACY")
        XCTAssertEqual(restored.permission, .ask)
        XCTAssertNil(restored.deletedAt)
        XCTAssertTrue(try destination.vault.listRecycledTextCredentials().isEmpty)
        XCTAssertThrowsError(try cloud.coordinator.backUp(snapshot: snapshot)) {
            XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot)
        }
    }

    func testUnsupportedSnapshotVersionsAreRejectedByUploadAndBothRestoreEntrypoints() throws {
        for version in [0, 3, 999] {
            let payload = legacyPayload(version: version)
            let snapshot = try JSONDecoder().decode(ICloudBackupSnapshot.self, from: payload)
            let cloud = try makeCloud()
            XCTAssertThrowsError(try cloud.coordinator.backUp(snapshot: snapshot)) {
                XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot)
            }
            try installAuthenticatedPayload(payload, cloud: cloud)
            XCTAssertThrowsError(try cloud.coordinator.restoreSelection()) {
                XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot)
            }
            let destination = try makeVault()
            XCTAssertThrowsError(try restore(snapshot, into: destination.vault)) {
                XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot)
            }
            XCTAssertTrue(try destination.vault.listTextCredentials().isEmpty)
        }
    }

    func testDuplicateNamesAndIDsAcrossActiveAndRecycledCredentialsRejectBeforeReplacement() throws {
        for duplicateName in [false, true] {
            let destination = try makeVault()
            let active = ICloudBackupCredential(
                id: "active", displayName: "Existing", payload: .text("SYNTHETIC_ACTIVE"), permission: .ask
            )
            let recycled = ICloudBackupCredential(
                id: duplicateName ? "recycled" : "active", displayName: duplicateName ? "existing" : "Other",
                payload: .text("SYNTHETIC_RECYCLED"), permission: .hidden,
                deletedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let snapshot = ICloudBackupSnapshot(credentials: [active, recycled], groupNames: [], settings: settings)
            let target = try VaultICloudBackupRestoreTarget(
                vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
            )
            XCTAssertThrowsError(try target.restoreLibraryAtomically(
                with: snapshot, persistLocalSafetySnapshot: { _ in XCTFail("Duplicate must not begin replacement") }
            )) { XCTAssertEqual($0 as? ICloudBackupError, .invalidSnapshot) }
            XCTAssertTrue(try destination.vault.listTextCredentials().isEmpty)
            XCTAssertTrue(try destination.vault.listRecycledTextCredentials().isEmpty)
        }
    }

    func testTamperedRecycleMetadataBlocksCloudAndSafetySnapshots() throws {
        let fixture = try makeVault()
        let active = try fixture.vault.createTextCredential(.init(name: "Active", value: "SYNTHETIC_ACTIVE"), using: .allow)
        let recycled = try fixture.vault.createTextCredential(.init(name: "Recycled", value: "SYNTHETIC_RECYCLED"), using: .allow)
        try fixture.vault.deleteTextCredential(id: recycled.id, using: .allow)
        // Simulate an external DB edit without the vault key; the original MAC remains.
        try fixture.store.db.write {
            try $0.execute(sql: "UPDATE credentials SET deleted_at = ? WHERE id = ?",
                           arguments: ["2020-01-01T00:00:00Z", recycled.id])
        }
        XCTAssertThrowsError(try fixture.vault.makeICloudBackupSnapshot(settings: settings)) {
            XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication)
        }
        let target = try VaultICloudBackupRestoreTarget(
            vault: fixture.vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        XCTAssertThrowsError(try target.restoreLibraryAtomically(
            with: ICloudBackupSnapshot(credentials: [], groupNames: [], settings: settings),
            persistLocalSafetySnapshot: { _ in XCTFail("Unauthenticated safety snapshot must not be persisted") }
        )) { XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication) }
        XCTAssertEqual(try fixture.vault.listTextCredentials().map(\.id), [active.id])
    }

    func testLegacyOffsetDeletionTimeSurvivesCloudAndSafetySnapshotRestore() throws {
        let originalDeletion = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-22T04:00:00Z"))
        for timestamp in [
            "2026-09-22T12:00:00+08:00", "2026-09-21T21:00:00-07:00",
            "2026-09-22T12:00:00+0800", "2026-09-22T04:00:00z",
        ] {
            let source = try makeVault()
            let credential = try source.vault.createTextCredential(
                .init(name: "Legacy Recycled", value: "SYNTHETIC_LEGACY", groupName: "Legacy Group"), using: .allow
            )
            // Historical migration preserves the offset string and seals it with the destination MAC.
            // Build that authenticated on-disk fixture through the same persistence boundary.
            try source.store.recycleCredential(id: credential.id, deletedAt: timestamp)
            XCTAssertEqual(try source.vault.listRecycledTextCredentials().first?.deletedAt, originalDeletion)
            let cloud = try makeCloud()
            _ = try source.vault.backUpToICloud(using: cloud.coordinator, settings: settings)
            let destination = try makeVault()
            let target = try VaultICloudBackupRestoreTarget(
                vault: destination.vault, currentSettings: { self.settings }, applySettings: { _ in }
            )
            try cloud.coordinator.restore(into: target, using: .allow, persistLocalSafetySnapshot: { _ in })
            XCTAssertTrue(try destination.vault.listTextCredentials().isEmpty)
            XCTAssertEqual(try destination.vault.listRecycledTextCredentials().first?.deletedAt, originalDeletion)

            var safety: Data?
            let sourceTarget = try VaultICloudBackupRestoreTarget(
                vault: source.vault, currentSettings: { self.settings }, applySettings: { _ in }
            )
            try sourceTarget.restoreLibraryAtomically(
                with: ICloudBackupSnapshot(credentials: [], groupNames: [], settings: settings),
                persistLocalSafetySnapshot: { safety = $0 }
            )
            let safetySnapshot = try JSONDecoder().decode(
                ICloudBackupSnapshot.self,
                from: VaultCrypto.decryptData(XCTUnwrap(safety), using: source.key)
            )
            try restore(safetySnapshot, into: source.vault)
            XCTAssertTrue(try source.vault.listTextCredentials().isEmpty)
            let recovered = try XCTUnwrap(source.vault.listRecycledTextCredentials().first)
            XCTAssertEqual(recovered.id, credential.id)
            XCTAssertEqual(recovered.deletedAt, originalDeletion)
            XCTAssertEqual(recovered.groupName, "Legacy Group")
            XCTAssertEqual(recovered.permission, .ask)
            try source.vault.restoreRecycledTextCredential(id: recovered.id, using: .allow)
            XCTAssertEqual(try source.vault.revealTextCredential(id: recovered.id, using: .allow).value, "SYNTHETIC_LEGACY")
        }
    }

    func testAuthenticatedMalformedDeletionTimesStillRejectBackup() throws {
        for timestamp in [
            "2026-02-30T12:00:00+08:00", "2026-09-22T12:00:00+99:00",
            "2026-09-22T12:00:00+08:00junk", "2026-09-22T12:00:00Z\n",
            "2026-09-22T12:00:00.125Z", String(repeating: "x", count: 1_000),
        ] {
            let fixture = try makeVault()
            let credential = try fixture.vault.createTextCredential(
                .init(name: "Malformed Recycled", value: "SYNTHETIC_INVALID_DATE"), using: .allow
            )
            try fixture.store.recycleCredential(id: credential.id, deletedAt: timestamp)
            XCTAssertThrowsError(try fixture.vault.makeICloudBackupSnapshot(settings: settings))
        }
    }

    private func restore(_ snapshot: ICloudBackupSnapshot, into vault: Vault) throws {
        let target = try VaultICloudBackupRestoreTarget(
            vault: vault, currentSettings: { self.settings }, applySettings: { _ in }
        )
        try target.restoreLibraryAtomically(with: snapshot, persistLocalSafetySnapshot: { _ in })
    }

    private func legacyPayload(version: Int) -> Data {
        Data("""
        {"formatVersion":\(version),"credentials":[{"id":"legacy","displayName":"Legacy",
        "payload":{"text":{"_0":"SYNTHETIC_LEGACY"}},"usageInstructions":"","privateNotes":"",
        "permission":"allowed"}],"groupNames":[],"settings":{"languageMode":"system",
        "appearanceMode":"system","defaultTimedAllowanceMinutes":5,"launchAtLogin":false}}
        """.utf8)
    }

    private typealias Cloud = (coordinator: ICloudBackupCoordinator, store: RecycleBackupStore, key: BackupRecoveryKey)

    private func makeCloud() throws -> Cloud {
        let store = RecycleBackupStore()
        let key = try BackupRecoveryKey(encoded: Data(repeating: 0x45, count: 32).base64EncodedString())
        return (try ICloudBackupCoordinator(
            store: store, recoveryKey: key, writerID: "11111111-1111-4111-8111-111111111111",
            stateStore: RecycleBackupState()
        ), store, key)
    }

    /// Fixture for the existing manifest v1 wire protocol, independent of the current snapshot encoder.
    private func installAuthenticatedPayload(_ payload: Data, cloud: Cloud) throws {
        let generation = "legacy-fixture"
        let writer = "11111111-1111-4111-8111-111111111111"
        let createdAt = "2026-01-01T00:00:00Z"
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: try XCTUnwrap(Data(base64Encoded: cloud.key.encoded))),
            salt: Data(cloud.key.keyID.utf8), info: Data("Ask Key iCloud backup v1".utf8), outputByteCount: 32
        )
        let aad = Data("1\n\(generation)\n\(cloud.key.keyID)\n\(writer)\n-\n\(createdAt)".utf8)
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: aad)
        let blob = try XCTUnwrap(sealed.combined)
        let manifest: [String: Any] = [
            "formatVersion": 1, "generationID": generation, "keyID": cloud.key.keyID,
            "writerID": writer, "createdAt": createdAt, "nonce": Data(sealed.nonce).base64EncodedString(),
            "ciphertextDigest": SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined(),
        ]
        let root = "askkey-backup/\(cloud.key.keyID)"
        try cloud.store.create(blob, at: "\(root)/generations/\(generation)/blob")
        try cloud.store.create(JSONSerialization.data(withJSONObject: manifest), at: "\(root)/generations/\(generation)/manifest.json")
        try cloud.store.create(JSONSerialization.data(withJSONObject: ["generationID": generation]), at: "\(root)/current.json")
        try cloud.store.create(JSONSerialization.data(withJSONObject: ["writerID": writer]), at: "\(root)/writer.json")
    }

    private func makeVault() throws -> (vault: Vault, key: SymmetricKey, store: VaultStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBackupRecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        addTeardownBlock { try? store.close() }
        let key = VaultCrypto.generateKey()
        let vault = Vault(
            store: store, key: key, now: { Date(timeIntervalSince1970: 1_790_000_000) },
            fileDeliveryManager: try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries"))
        )
        try vault.beginManagementSession(using: .allow)
        return (vault, key, store)
    }
}

private final class RecycleBackupStore: ICloudBackupStore {
    var files: [String: Data] = [:]
    func create(_ data: Data, at path: String) throws {
        guard files[path] == nil else { throw ICloudBackupStoreError.alreadyExists }
        files[path] = data
    }
    func replace(_ data: Data, at path: String) throws { files[path] = data }
    func read(at path: String) throws -> Data? { files[path] }
    func list(prefix: String) throws -> [String] { files.keys.filter { $0.hasPrefix(prefix) } }
    func conflictPaths(prefix: String) throws -> [String] { [] }
    func resolveConflicts(prefix: String) throws {}
    func delete(at path: String) throws { files.removeValue(forKey: path) }
}

private final class RecycleBackupState: ICloudBackupLocalStateStore {
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
