import CryptoKit
import Foundation
import Observation
import AskKeyBroker
import UserNotifications
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyCore

@MainActor
final class Batch4SettingsLanguageTests: AskKeyAppTestCase {
    func testLockedReminderPresentationIsGenericInBothLanguages() {
        for language in ["en", "zh-Hans"] {
            switch AgentApprovalPrivacyPolicy.plan(screenState: .locked, language: language) {
            case let .lockedReminder(title, body):
                let joined = title + "\n" + body
                XCTAssertEqual(
                    title,
                    AppLanguage.localized("Ask Key has pending requests", language: language)
                )
                XCTAssertEqual(
                    body,
                    AppLanguage.localized(
                        "Unlock your Mac to review a pending request.",
                        language: language
                    )
                )
                XCTAssertFalse(joined.localizedCaseInsensitiveContains("purpose"))
                XCTAssertFalse(joined.contains("用途"))
                XCTAssertFalse(joined.localizedCaseInsensitiveContains("caller"))
                XCTAssertFalse(joined.contains("调用方"))
                XCTAssertFalse(joined.localizedCaseInsensitiveContains("credential:"))
                XCTAssertFalse(joined.contains("凭证："))
            case .detailedConfirmation:
                XCTFail("locked reminder must stay generic")
            }
        }
    }

    func testDisableReadAuthenticationAndMissingErrorsPresentInBothLanguages() throws {
        let suite = "AskKey.ReadPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = ReadPreferenceRecorder()
        let machine = BrokerApprovalStateMachine(authenticate: {
            recorder.record($0)
            return true
        })
        let model = VaultViewModel(
            runtimeFileCleanupFailures: { false }, accessRecords: .empty,
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            updateReadAuthentication: { machine.setReadAuthenticationEnabled($0) },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        for enabled in [true, false] {
            let observation = ReadPreferenceRecorder()
            withObservationTracking { _ = model.readApprovalAuthenticationEnabled } onChange: {
                observation.recordChange()
            }
            model.readApprovalAuthenticationEnabled = enabled
            XCTAssertTrue(observation.changed)
            XCTAssertEqual(AppPreferences(defaults: defaults).readApprovalAuthenticationEnabled, enabled)
            for operation in [BrokerApprovalOperation.read, .create, .modify] {
                let before = recorder.purposes
                let ticket = try machine.submit(.init(
                    operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
                    operation: operation, payloadDigest: String(repeating: "a", count: 64)
                ), trustedCredentialDeadline: .none)
                XCTAssertEqual(ticket.state, .pending)
                XCTAssertEqual(recorder.purposes, before)
                XCTAssertEqual(try machine.decide(
                    requestID: ticket.requestID, capability: ticket.capability, decision: .once
                ).state, .approved)
                let purpose: BrokerAuthenticationPurpose = operation == .read ? .readApproval : .writeApproval
                XCTAssertEqual(recorder.purposes, operation == .read && !enabled ? before : before + [purpose])
            }
        }

        let disable = ManagementAuthenticationAction.disableReadAuthentication.reasonKey
        XCTAssertEqual(
            ManagementAuthenticationPresentation(reasonKey: disable, language: "en").reason,
            "Disable system authentication for read approvals"
        )
        XCTAssertEqual(
            ManagementAuthenticationPresentation(reasonKey: disable, language: "zh-Hans").reason,
            "关闭批准读取的系统验证"
        )

        let errors = [
            "Ask Key could not save an access record. Credential operations continue, and this warning will remain until recording succeeds.",
            "Ask Key could not prepare Agent access. Open the app to review the vault state.",
            "Ask Key could not apply this decision. Open Pending requests to retry or reject it.",
            "Ask Key could not clean up expired recycled credentials.",
            "Ask Key could not remove a temporary credential file. It will keep retrying.",
            CredentialExpiryReminderCopy.authorizationDeniedKey,
            CredentialExpiryReminderCopy.deliveryFailedKey,
        ]
        for key in errors {
            XCTAssertEqual(AppLanguage.localized(key, language: "en"), key)
            let chinese = AppLanguage.localized(key, language: "zh-Hans")
            XCTAssertNotEqual(chinese, key)
            XCTAssertFalse(chinese.isEmpty)
        }
    }

    func testFrozenWriteRevealAndApprovalReasonsStayLanguagePure() {
        AppLanguage.current = "zh-Hans"
        let chineseReveal = FrozenWriteRevealCopy.content(before: "old", after: "new")
        XCTAssertTrue(chineseReveal.contains("修改前"))
        XCTAssertTrue(chineseReveal.contains("修改后"))
        XCTAssertFalse(chineseReveal.contains("Before"))
        XCTAssertFalse(chineseReveal.contains("After"))
        XCTAssertEqual(
            AppLanguage.table(language: "zh-Hans")["Approve this Agent credential request"],
            "授权 AI 助手使用所选凭证"
        )
        XCTAssertEqual(
            AppLanguage.table(language: "zh-Hans")["Approve this Agent credential change"],
            "授权 AI 助手修改所选凭证"
        )

        AppLanguage.current = "en"
        let englishReveal = FrozenWriteRevealCopy.content(before: "old", after: "new")
        XCTAssertTrue(englishReveal.contains("Before"))
        XCTAssertTrue(englishReveal.contains("After"))
        XCTAssertFalse(englishReveal.contains("修改前"))
        XCTAssertFalse(englishReveal.contains("修改后"))
        AppLanguage.current = "en"
    }

    func testTimedAllowMinutesAndHotkeyOffAreUserControllable() {
        let suite = "AskKey.batch4.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let viewModel = VaultViewModel(
            preferences: AppPreferences(defaults: defaults),
            updateTimedAllowance: { _ in }
        )
        viewModel.defaultTimedAllowanceMinutes = 120
        XCTAssertEqual(AppPreferences(defaults: defaults).defaultTimedAllowanceMinutes, 120)
        XCTAssertTrue(
            FrozenTimedAllowanceSettingsPresentation.help(minutes: 15).contains("15")
        )
        XCTAssertFalse(
            FrozenTimedAllowanceSettingsPresentation.help(minutes: 15).contains("30-minute")
        )
        XCTAssertEqual(FrozenTimedAllowanceSettingsPresentation.choices, [15, 30, 60, 120])

        XCTAssertTrue(FrozenHotkeySettingsPresentation.includesOff)
        XCTAssertEqual(
            FrozenHotkeySettingsPresentation.optionIDs,
            GlobalHotkeyManager.Shortcut.allOptions.map(\.id)
        )
        XCTAssertFalse(GlobalHotkeyManager.Shortcut.canRegister(.disabled))
        XCTAssertEqual(GlobalHotkeyManager.Shortcut.fromID("disabled"), .disabled)
        let manager = GlobalHotkeyManager()
        manager.register(.disabled)
        XCTAssertNil(manager.registeredShortcut)
        viewModel.hotkeyShortcutID = "disabled"
        XCTAssertEqual(AppPreferences(defaults: defaults).hotkeyShortcutID, "disabled")
    }

    func testGitHubAppTemplateStaysOnTheGenericComponentModel() throws {
        var drafts = CredentialTemplate.githubApp.components
        for index in drafts.indices {
            if drafts[index].kind == .file {
                drafts[index].file = try FileImport.FrozenFile(
                    originalFilename: "app.pem",
                    bytes: Data("synthetic-pem".utf8)
                )
            } else if !drafts[index].isOptional {
                drafts[index].text = "synthetic"
            }
        }
        XCTAssertTrue(CredentialEditorComponentValidation.canSave(drafts))
        let inputs = try XCTUnwrap(CredentialEditorComponentValidation.inputs(drafts))
        XCTAssertEqual(
            inputs.map(\.name),
            ["GITHUB_APP_ID", "GITHUB_CLIENT_ID", "GITHUB_CLIENT_SECRET", "GITHUB_PRIVATE_KEY"]
        )
        XCTAssertEqual(
            CredentialTemplate.prototypeTemplate(componentNames: Set(inputs.map(\.name))),
            .githubApp
        )
        XCTAssertTrue(CredentialTemplate.allCases.contains(.database))
        XCTAssertTrue(CredentialTemplate.allCases.contains(.custom))
        XCTAssertEqual(ExpiryReminderNotificationCopy.title(language: "en"), "Ask Key has a credential expiring soon")
        XCTAssertEqual(ExpiryReminderNotificationCopy.title(language: "zh-Hans"), "请旨有凭证即将到期")
        XCTAssertFalse(ExpiryReminderNotificationCopy.body(language: "en").localizedCaseInsensitiveContains("purpose"))
        XCTAssertFalse(ExpiryReminderNotificationCopy.body(language: "zh-Hans").contains("用途"))
    }

    func testExpiryControllerReportsDeniedPermissionAndDeduplicatesLaunch() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyBatch4Expiry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(
            store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
            key: SymmetricKey(data: Data(repeating: 0x31, count: 32)),
            now: { now }
        )
        try vault.beginManagementSession(using: .allow)
        let created = try vault.createTextCredential(
            .init(
                name: "Batch Four Expiry",
                value: "SYNTHETIC",
                permission: .ask,
                expiresAt: now.addingTimeInterval(2 * 24 * 60 * 60)
            ),
            using: .allow
        )

        let suite = "AskKey.batch4.expiry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var deliveries: [String] = []
        let denied = expectation(description: "denied")
        let deniedController = CredentialExpiryReminderController(
            vault: { vault },
            now: { now },
            defaults: defaults,
            ledgerKey: "ledger",
            notificationCenter: ExpiryReminderNotificationCenter(
                loadAuthorizationStatus: { $0(.denied) },
                requestAuthorization: { $0(false) },
                add: { _, completion in completion(nil) },
                remove: { _ in }
            )
        )
        deniedController.onAuthorizationFailure = { message in
            XCTAssertEqual(message, CredentialExpiryReminderCopy.authorizationDeniedKey)
            denied.fulfill()
        }
        deniedController.reconcile()
        await fulfillment(of: [denied], timeout: 1)
        XCTAssertTrue(deliveries.isEmpty)

        let delivered = expectation(description: "delivered")
        let allowedController = CredentialExpiryReminderController(
            vault: { vault },
            now: { now },
            defaults: defaults,
            ledgerKey: "ledger",
            notificationCenter: ExpiryReminderNotificationCenter(
                loadAuthorizationStatus: { $0(.authorized) },
                requestAuthorization: { $0(true) },
                add: { request, completion in
                    let prefix = "askkey-expiry-"
                    let identifier = request.identifier
                    if identifier.hasPrefix(prefix) {
                        deliveries.append(String(identifier.dropFirst(prefix.count)))
                    }
                    completion(nil)
                    delivered.fulfill()
                },
                remove: { _ in }
            )
        )
        allowedController.reconcile()
        await fulfillment(of: [delivered], timeout: 1)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(deliveries, [created.id])

        allowedController.reconcile()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(deliveries, [created.id])
    }
}

private final class ReadPreferenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BrokerAuthenticationPurpose] = []
    private var didChange = false
    var purposes: [BrokerAuthenticationPurpose] { lock.lock(); defer { lock.unlock() }; return values }
    var changed: Bool { lock.lock(); defer { lock.unlock() }; return didChange }
    func record(_ purpose: BrokerAuthenticationPurpose) { lock.lock(); values.append(purpose); lock.unlock() }
    func recordChange() { lock.lock(); didChange = true; lock.unlock() }
}
