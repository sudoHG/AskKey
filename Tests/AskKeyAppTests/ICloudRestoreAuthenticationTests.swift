import CryptoKit
import Foundation
import Observation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore
@testable import AskKeyBroker

@MainActor
final class ICloudRestoreAuthenticationTests: XCTestCase {
    func testPendingRestorePersistsReadAuthenticationForRestart() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyRestoreAuthentication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "AskKey.RestoreAuthentication.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.readApprovalAuthenticationEnabled = false
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        let key = VaultCrypto.generateKey()
        let path = root.appendingPathComponent("vault.db").path
        let originalStore = try VaultStore(path: path)
        let original = Vault(
            store: originalStore, key: key,
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("original-deliveries"))
        )
        try original.beginManagementSession(using: .allow)
        let settings = ICloudBackupSettings(
            languageMode: "en", appearanceMode: "dark", defaultTimedAllowanceMinutes: 15, launchAtLogin: false
        )
        enum Interrupted: Error { case afterCommit }
        XCTAssertThrowsError(try original.restoreLibraryFromICloudBackup(
            .init(credentials: [], groupNames: [], settings: settings), currentSettings: { settings },
            persistLocalSafetySnapshot: { _ in }, applySettings: { _ in },
            afterDatabaseReplace: { throw Interrupted.afterCommit }
        ))
        try originalStore.close()
        let reopenedStore = try VaultStore(path: path)
        addTeardownBlock { try? reopenedStore.close() }
        let authentication = AuthenticationRecorder()
        let reopened = Vault(
            store: reopenedStore, key: key,
            approvalRequests: authentication.makeMachine(),
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("reopened-deliveries"))
        )
        reopened.approvalRequests.setReadAuthenticationEnabled(false)
        var model: VaultViewModel? = makeModel(vault: reopened, preferences: preferences)
        let observation = AuthenticationObservation()
        withObservationTracking { _ = model?.readApprovalAuthenticationEnabled } onChange: { observation.record() }
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { XCTFail("Pending recovery is local"); throw ICloudBackupError.containerUnavailable },
            materials: AuthenticationUnusedMaterialStore(),
            state: UserDefaultsICloudBackupLocalStateStore(
                defaults: defaults, pendingUploadDirectory: root.appendingPathComponent("pending")
            ),
            safetySnapshots: LocalICloudSafetySnapshotStore(directory: root.appendingPathComponent("safety")),
            preferences: preferences,
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            dirtyDefaults: defaults, dirtyKey: "authentication-dirty"
        )

        try controller.prepareAgentRuntime(vault: reopened)
        model?.adoptRestoredPreferences()

        XCTAssertNil(try reopenedStore.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertTrue(preferences.readApprovalAuthenticationEnabled)
        XCTAssertEqual(model?.readApprovalAuthenticationEnabled, true)
        XCTAssertTrue(observation.changed)
        try assertOnceRequiresDecision(vault: reopened, recorder: authentication, expectedAuthentication: true)
        weak var retiredModel = model
        model = nil
        XCTAssertNil(retiredModel)
        let recreatedPreferences = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(recreatedPreferences.readApprovalAuthenticationEnabled)
        let restartedAuthentication = AuthenticationRecorder()
        let restarted = Vault(
            store: reopenedStore, key: key, approvalRequests: restartedAuthentication.makeMachine(),
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("next-launch-deliveries"))
        )
        let recreatedModel = makeModel(vault: restarted, preferences: recreatedPreferences)
        XCTAssertTrue(recreatedModel.readApprovalAuthenticationEnabled)
        try assertOnceRequiresDecision(vault: restarted, recorder: restartedAuthentication, expectedAuthentication: true)
    }

    func testOrdinaryRestorePersistsAndObservesAuthenticationWithoutSkippingAskOrChangingWriteAuthentication() async throws {
        let fixture = try makeNormalFixture()
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        var model: VaultViewModel? = makeModel(vault: fixture.vault, preferences: fixture.preferences) { key, id, auth in
            try fixture.controller.restore(recoveryKey: key, generationID: id, using: auth, vault: fixture.vault)
        }
        XCTAssertEqual(model?.readApprovalAuthenticationEnabled, false)
        try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, expectedAuthentication: false)
        for operation in [BrokerApprovalOperation.create, .modify] {
            try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, operation: operation, expectedAuthentication: true)
        }
        let observation = AuthenticationObservation()
        withObservationTracking { _ = model?.readApprovalAuthenticationEnabled } onChange: { observation.record() }

        let restored = await model?.restoreICloudBackup(recoveryKey: fixture.key.encoded, generationID: fixture.generation.id)

        XCTAssertEqual(restored, fixture.generation)
        XCTAssertEqual(model?.readApprovalAuthenticationEnabled, true)
        XCTAssertTrue(observation.changed)
        XCTAssertTrue(fixture.preferences.readApprovalAuthenticationEnabled)
        XCTAssertEqual(try fixture.vault.listTextCredentials().map(\.permission), [.ask])
        try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, expectedAuthentication: true)
        for operation in [BrokerApprovalOperation.create, .modify] {
            try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, operation: operation, expectedAuthentication: true)
        }

        weak var retiredModel = model
        model = nil
        XCTAssertNil(retiredModel)
        let recreatedPreferences = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: fixture.suite)))
        let nextAuthentication = AuthenticationRecorder()
        let nextVault = Vault(
            store: fixture.store, key: fixture.vaultKey, approvalRequests: nextAuthentication.makeMachine(),
            fileDeliveryManager: try FileDeliveryManager(rootURL: fixture.root.appendingPathComponent("next-deliveries"))
        )
        let nextModel = makeModel(vault: nextVault, preferences: recreatedPreferences)
        XCTAssertTrue(nextModel.readApprovalAuthenticationEnabled)
        try assertOnceRequiresDecision(vault: nextVault, recorder: nextAuthentication, expectedAuthentication: true)
    }

    func testFailedOrdinaryRestoreSynchronizesSafePreferenceWhileJournalWaitsForLocalRetry() async throws {
        let fixture = try makeNormalFixture()
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        let model = makeModel(vault: fixture.vault, preferences: fixture.preferences) { key, id, auth in
            try fixture.controller.restore(recoveryKey: key, generationID: id, using: auth, vault: fixture.vault)
        }
        fixture.login.shouldFail = true
        let observation = AuthenticationObservation()
        withObservationTracking { _ = model.readApprovalAuthenticationEnabled } onChange: { observation.record() }

        let restored = await model.restoreICloudBackup(recoveryKey: fixture.key.encoded, generationID: fixture.generation.id)

        XCTAssertNil(restored)
        XCTAssertTrue(observation.changed)
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        XCTAssertTrue(fixture.preferences.readApprovalAuthenticationEnabled)
        XCTAssertTrue(model.isAgentAccessPaused)
        XCTAssertNotEqual(model.iCloudBackupStatusCopy, "Backup restored. The local credential list is up to date.")
        let journal = try XCTUnwrap(fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertThrowsError(try fixture.vault.brokerCredentialCatalog(cancellation: .init()))
        XCTAssertThrowsError(try fixture.controller.prepareAgentRuntime(vault: fixture.vault))
        XCTAssertEqual(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey), journal)
        XCTAssertTrue(fixture.preferences.readApprovalAuthenticationEnabled)
        fixture.login.shouldFail = false
        try fixture.controller.prepareAgentRuntime(vault: fixture.vault)
        model.adoptRestoredPreferences()
        model.refreshAgentAccessPauseState()
        XCTAssertNil(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertFalse(model.isAgentAccessPaused)
        XCTAssertTrue(model.readApprovalAuthenticationEnabled)
        try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, expectedAuthentication: true)
    }

    func testReadAuthenticationToggleNotifiesAndUpdatesOnlyTheInjectedMachine() throws {
        let fixture = try makeNormalFixture()
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        let model = makeModel(vault: fixture.vault, preferences: fixture.preferences)
        for enabled in [true, false] {
            let observation = AuthenticationObservation()
            withObservationTracking { _ = model.readApprovalAuthenticationEnabled } onChange: { observation.record() }
            model.readApprovalAuthenticationEnabled = enabled
            XCTAssertTrue(observation.changed)
            XCTAssertEqual(fixture.preferences.readApprovalAuthenticationEnabled, enabled)
            try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, expectedAuthentication: enabled)
            for operation in [BrokerApprovalOperation.create, .modify] {
                try assertOnceRequiresDecision(vault: fixture.vault, recorder: fixture.authentication, operation: operation, expectedAuthentication: true)
            }
        }
    }

    private func assertOnceRequiresDecision(
        vault: Vault, recorder: AuthenticationRecorder, operation: BrokerApprovalOperation = .read,
        expectedAuthentication: Bool
    ) throws {
        let before = recorder.calls
        let request = BrokerApprovalOperationRequest(
            operationID: UUID().uuidString, credentialID: "restored", targetID: "restored",
            operation: operation, payloadDigest: String(repeating: "b", count: 64)
        )
        let ticket = try vault.approvalRequests.submit(request, trustedCredentialDeadline: .none)
        XCTAssertEqual(ticket.state, .pending, "System authentication preference must never skip Ask")
        XCTAssertEqual(recorder.calls, before)
        XCTAssertEqual(try vault.approvalRequests.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once
        ).state, .approved)
        let expectedPurpose: BrokerAuthenticationPurpose = operation == .read ? .readApproval : .writeApproval
        XCTAssertEqual(recorder.calls, expectedAuthentication ? before + [expectedPurpose] : before)
    }

    private func makeModel(
        vault: Vault, preferences: AppPreferences,
        restore: @escaping @MainActor (String, String, ManagementAuthenticator) throws -> ICloudBackupGeneration = { _, _, _ in
            throw ICloudBackupError.containerUnavailable
        }
    ) -> VaultViewModel {
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false }, accessRecords: .empty,
            restoreICloudBackup: restore, authenticateICloudLifecycle: { _ in .allow },
            unlockVault: {}, beginManagementSession: { try vault.beginManagementSession(using: $0) },
            preferences: preferences,
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            updateTimedAllowance: { vault.updateDefaultTimedAllowanceMinutes($0) },
            updateReadAuthentication: { vault.approvalRequests.setReadAuthenticationEnabled($0) },
            isAgentAccessPaused: { try vault.isAgentAccessPaused() },
            credentialMutations: .readOnly {
                (try vault.listTextCredentials(), try vault.listRecycledTextCredentials(), try vault.listCredentialGroups(), false)
            }.counting { try vault.storedCredentialCount() }
        )
        model.isLocked = vault.isLocked
        model.hasManagementSession = vault.hasActiveManagementSession
        return model
    }

    private func makeNormalFixture() throws -> NormalFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAuthenticationCloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "AskKey.AuthenticationCloud.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.readApprovalAuthenticationEnabled = false
        let authentication = AuthenticationRecorder()
        let store = try VaultStore(path: root.appendingPathComponent("vault.db").path)
        addTeardownBlock { try? store.close() }
        let vaultKey = VaultCrypto.generateKey()
        let vault = Vault(
            store: store, key: vaultKey, approvalRequests: authentication.makeMachine(),
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        )
        try vault.beginManagementSession(using: .allow)
        let cloud = AuthenticationCloudStore()
        let material = try ICloudBackupKeyMaterial.generate()
        let state = UserDefaultsICloudBackupLocalStateStore(
            defaults: defaults, pendingUploadDirectory: root.appendingPathComponent("pending")
        )
        let coordinator = try ICloudBackupCoordinator(store: cloud, material: material, stateStore: state)
        let snapshot = ICloudBackupSnapshot(
            credentials: [.init(id: "restored", displayName: "Restored", payload: .text("SYNTHETIC_VALUE"), permission: .allowed)],
            groupNames: [], settings: .init(languageMode: "en", appearanceMode: "dark", defaultTimedAllowanceMinutes: 15, launchAtLogin: false)
        )
        let generation = try coordinator.backUp(
            snapshot: snapshot, createdAt: Date(timeIntervalSince1970: 1_790_035_200)
        )
        let login = AuthenticationLoginState()
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { cloud }, materials: AuthenticationMaterialStore(material: material), state: state,
            safetySnapshots: LocalICloudSafetySnapshotStore(directory: root.appendingPathComponent("safety")),
            preferences: preferences,
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in
                if login.shouldFail { throw AuthenticationTestFailure.loginItem }
            }), dirtyDefaults: defaults, dirtyKey: "authentication-cloud-dirty"
        )
        return .init(root: root, suite: suite, preferences: preferences, vault: vault, store: store, vaultKey: vaultKey,
                     authentication: authentication, controller: controller, key: material.recoveryKey, generation: generation, login: login)
    }

    private struct NormalFixture {
        let root: URL
        let suite: String
        let preferences: AppPreferences
        let vault: Vault
        let store: VaultStore
        let vaultKey: SymmetricKey
        let authentication: AuthenticationRecorder
        let controller: ICloudAppLifecycleController
        let key: BackupRecoveryKey
        let generation: ICloudBackupGeneration
        let login: AuthenticationLoginState
    }
}

private final class AuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BrokerAuthenticationPurpose] = []
    var calls: [BrokerAuthenticationPurpose] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
    func makeMachine() -> BrokerApprovalStateMachine {
        BrokerApprovalStateMachine(authenticate: { purpose in
            self.lock.lock(); self.recorded.append(purpose); self.lock.unlock()
            return true
        })
    }
}

private final class AuthenticationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var didChange = false
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return didChange }
    func record() { lock.lock(); didChange = true; lock.unlock() }
}

private final class AuthenticationLoginState { var shouldFail = false }
private enum AuthenticationTestFailure: Error { case loginItem }

private struct AuthenticationMaterialStore: ICloudBackupMaterialStore {
    let material: ICloudBackupKeyMaterial
    func save(_ material: ICloudBackupKeyMaterial) throws { XCTFail("Fixture material already exists") }
    func load(keyID: String) throws -> ICloudBackupKeyMaterial? { keyID == material.recoveryKey.keyID ? material : nil }
    func delete(keyID: String) throws { XCTFail("Existing material must not be removed after local settings failure") }
}

private final class AuthenticationCloudStore: ICloudBackupStore {
    private var files: [String: Data] = [:]
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

private struct AuthenticationUnusedMaterialStore: ICloudBackupMaterialStore {
    func save(_ material: ICloudBackupKeyMaterial) throws { XCTFail("Unexpected recovery material write") }
    func load(keyID: String) throws -> ICloudBackupKeyMaterial? { XCTFail("Unexpected recovery material read"); return nil }
    func delete(keyID: String) throws { XCTFail("Unexpected recovery material delete") }
}
