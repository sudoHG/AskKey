import CryptoKit
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore
@testable import AskKeyBroker

@MainActor
final class ICloudRestoreLaunchRecoveryTests: XCTestCase {
    func testProductionPreparationRecoversCommittedRestoreAfterDatabaseReopensOffline() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(try fixture.vault.isAgentAccessPaused())
        XCTAssertFalse(fixture.vault.hasActiveManagementSession)
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }

        try fixture.controller.prepareAgentRuntime(vault: fixture.vault)

        XCTAssertNil(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertEqual(fixture.preferences.appearanceMode, "dark")
        XCTAssertEqual(fixture.preferences.languageMode, "zh-Hans")
        XCTAssertEqual(fixture.preferences.defaultTimedAllowanceMinutes, 15)
        XCTAssertTrue(fixture.login.enabled)
        XCTAssertFalse(try fixture.vault.isAgentAccessPaused())
        XCTAssertFalse(fixture.vault.hasActiveManagementSession)
        XCTAssertEqual(try fixture.vault.brokerCredentialCatalog(cancellation: .init()).map(\.name), ["Restored"])
        try assertDefaultTimedAllowance(minutes: 15, vault: fixture.vault)
    }

    func testFailedSettingsApplicationKeepsJournalPausedAndLocalRetryPreservesLaterEdits() throws {
        let fixture = try makeFixture()
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        fixture.login.shouldFail = true
        let journal = try XCTUnwrap(fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        var failure: Error?
        XCTAssertThrowsError(try fixture.controller.prepareAgentRuntime(vault: fixture.vault)) { failure = $0 }
        guard case ICloudAppLifecycleError.restoreSettingsRecoveryFailed = try XCTUnwrap(failure) else {
            return XCTFail("Expected a specific local settings recovery failure")
        }
        let message = BrokerRuntimeFailure.userFacing(for: try XCTUnwrap(failure))
        XCTAssertTrue(message.canRetry)
        XCTAssertTrue(message.message.contains("restoring local settings"))
        XCTAssertFalse(message.message.contains("folder"))
        XCTAssertEqual(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey), journal)
        XCTAssertTrue(try fixture.vault.isAgentAccessPaused())
        XCTAssertThrowsError(try fixture.vault.brokerCredentialCatalog(cancellation: .init()))
        XCTAssertThrowsError(try fixture.vault.resumeAgentAccess(using: .allow))

        try fixture.vault.beginManagementSession(using: .allow)
        _ = try fixture.vault.updateTextCredential(
            id: "restored", .init(name: "Edited", value: "SYNTHETIC_EDITED"), using: .allow
        )
        let later = try fixture.vault.createTextCredential(
            .init(name: "Later", value: "SYNTHETIC_LATER"), using: .allow
        )
        var recovery = BrokerRuntimeRecovery(
            isRunning: { false },
            start: { try fixture.controller.prepareAgentRuntime(vault: fixture.vault) }
        )
        XCTAssertFalse(recovery.retry())
        XCTAssertEqual(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey), journal)
        fixture.login.shouldFail = false
        XCTAssertTrue(recovery.retry())
        XCTAssertNil(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertFalse(try fixture.vault.isAgentAccessPaused())
        XCTAssertEqual(try fixture.vault.listTextCredentials().map(\.name), ["Edited", "Later"])
        XCTAssertEqual(try fixture.vault.revealTextCredential(id: "restored", using: .allow).value, "SYNTHETIC_EDITED")
        XCTAssertEqual(try fixture.vault.revealTextCredential(id: later.id, using: .allow).value, "SYNTHETIC_LATER")
        XCTAssertEqual(fixture.login.calls, [true, true, true])
        try fixture.controller.prepareAgentRuntime(vault: fixture.vault)
        XCTAssertEqual(fixture.login.calls, [true, true, true], "Cleared journals must not replay")
    }

    func testPreparationWithoutJournalPreservesSettingsAndExistingReadAuthenticationChoice() throws {
        let fixture = try makeFixture(hasPendingRestore: false)
        fixture.vault.approvalRequests.setReadAuthenticationEnabled(false)
        fixture.vault.approvalRequests.configureAuthentication { _ in false }
        fixture.vault.updateDefaultTimedAllowanceMinutes(45)
        let previousLanguage = AppLanguage.store.mode
        defer { AppLanguage.apply(mode: previousLanguage) }
        AppLanguage.apply(mode: "en")

        try fixture.controller.prepareAgentRuntime(vault: fixture.vault)

        XCTAssertNil(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
        XCTAssertEqual(fixture.preferences.appearanceMode, "light")
        XCTAssertEqual(fixture.preferences.languageMode, "en")
        XCTAssertEqual(fixture.preferences.defaultTimedAllowanceMinutes, 30)
        XCTAssertEqual(AppLanguage.store.mode, "en")
        XCTAssertTrue(fixture.login.calls.isEmpty)
        XCTAssertFalse(try fixture.vault.isAgentAccessPaused())
        XCTAssertFalse(fixture.vault.hasActiveManagementSession)
        XCTAssertEqual(try fixture.vault.brokerCredentialCatalog(cancellation: .init()).map(\.name), ["Existing"])
        // Authentication would fail if an unrelated startup reset the person's choice.
        try assertDefaultTimedAllowance(minutes: 45, vault: fixture.vault)
    }

    func testPreparationPreservesExplicitPauseWithAndWithoutPendingRestore() throws {
        for hasPendingRestore in [false, true] {
            let fixture = try makeFixture(hasPendingRestore: hasPendingRestore, userPaused: true)
            let previousLanguage = AppLanguage.store.mode
            defer { AppLanguage.apply(mode: previousLanguage) }

            try fixture.controller.prepareAgentRuntime(vault: fixture.vault)

            XCTAssertNil(try fixture.store.configValue(key: VaultStore.iCloudRestorePendingSettingsKey))
            XCTAssertTrue(try fixture.vault.isAgentAccessPaused())
            XCTAssertThrowsError(try fixture.vault.brokerCredentialCatalog(cancellation: .init()))
            XCTAssertEqual(try fixture.store.configValue(key: Vault.agentAccessPausedConfigKey), "true")
            XCTAssertEqual(fixture.login.calls, hasPendingRestore ? [true] : [])
        }
    }

    private func assertDefaultTimedAllowance(minutes: Int, vault: Vault) throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let machine = vault.approvalRequests
        let ticket = try machine.submit(.init(
            operationID: UUID().uuidString, credentialID: "duration-check", targetID: "duration-check",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), now: start)
        XCTAssertEqual(try machine.decide(
            requestID: ticket.requestID, capability: ticket.capability,
            decision: .timedAllow(duration: nil), now: start
        ).state, .approved)
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "duration-check"), start.addingTimeInterval(Double(minutes * 60)))
    }

    private func makeFixture(hasPendingRestore: Bool = true, userPaused: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyRestoreLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let suite = "AskKey.RestoreLaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "en"
        preferences.appearanceMode = "light"
        preferences.defaultTimedAllowanceMinutes = 30
        let key = VaultCrypto.generateKey()
        let database = root.appendingPathComponent("vault.db")
        let originalStore = try VaultStore(path: database.path)
        let original = Vault(
            store: originalStore, key: key,
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("original-deliveries"))
        )
        try original.beginManagementSession(using: .allow)
        if userPaused { try original.pauseAgentAccess(using: .allow) }
        let settings = ICloudBackupSettings(
            languageMode: "zh-Hans", appearanceMode: "dark", defaultTimedAllowanceMinutes: 15, launchAtLogin: true
        )
        if hasPendingRestore {
            XCTAssertThrowsError(try original.restoreLibraryFromICloudBackup(
                .init(credentials: [.init(
                    id: "restored", displayName: "Restored", payload: .text("SYNTHETIC_RESTORED"), permission: .allowed
                )], groupNames: [], settings: settings),
                currentSettings: { settings }, persistLocalSafetySnapshot: { _ in }, applySettings: { _ in },
                afterDatabaseReplace: { throw InjectedFailure.afterDatabaseCommit }
            )) { XCTAssertEqual($0 as? InjectedFailure, .afterDatabaseCommit) }
        } else {
            _ = try original.createTextCredential(.init(name: "Existing", value: "SYNTHETIC_EXISTING"), using: .allow)
        }
        try originalStore.close()
        let reopenedStore = try VaultStore(path: database.path)
        addTeardownBlock { try? reopenedStore.close() }
        let reopened = Vault(
            store: reopenedStore, key: key,
            approvalRequests: BrokerApprovalStateMachine(
                clock: { Date(timeIntervalSince1970: 1_790_000_000) }, authenticate: { _ in true }
            ),
            fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("reopened-deliveries"))
        )
        let login = LoginState()
        let controller = ICloudAppLifecycleController(
            makeCloudStore: { XCTFail("Local recovery must not access iCloud"); throw ICloudBackupError.containerUnavailable },
            materials: UnusedRecoveryMaterialStore(),
            state: UserDefaultsICloudBackupLocalStateStore(
                defaults: defaults, pendingUploadDirectory: root.appendingPathComponent("pending-uploads")
            ),
            safetySnapshots: LocalICloudSafetySnapshotStore(directory: root.appendingPathComponent("safety")),
            preferences: preferences,
            loginItem: LoginItemController(isEnabled: { login.enabled }, setEnabled: {
                login.calls.append($0)
                if login.shouldFail { throw InjectedFailure.loginItem }
                login.enabled = $0
            }),
            dirtyDefaults: defaults, dirtyKey: "restore-launch-dirty"
        )
        return Fixture(vault: reopened, store: reopenedStore, preferences: preferences, controller: controller, login: login)
    }

    private struct Fixture {
        let vault: Vault
        let store: VaultStore
        let preferences: AppPreferences
        let controller: ICloudAppLifecycleController
        let login: LoginState
    }

    private final class LoginState {
        var enabled = false
        var shouldFail = false
        var calls: [Bool] = []
    }

    private enum InjectedFailure: Error, Equatable {
        case afterDatabaseCommit
        case loginItem
    }
}

private struct UnusedRecoveryMaterialStore: ICloudBackupMaterialStore {
    func save(_ material: ICloudBackupKeyMaterial) throws { XCTFail("Local recovery must not write recovery material") }
    func load(keyID: String) throws -> ICloudBackupKeyMaterial? { XCTFail("Local recovery must not read recovery material"); return nil }
    func delete(keyID: String) throws { XCTFail("Local recovery must not delete recovery material") }
}
