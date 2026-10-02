import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

@MainActor
final class AppLanguageExperienceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AskKey.language.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        AppLanguage.systemLanguages = { ["en-US"] }
        AppLanguage.current = "en"
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        AppLanguage.systemLanguages = { Locale.preferredLanguages }
        AppLanguage.current = "en"
        super.tearDown()
    }

    func testFollowSystemSimplifiedChineseAndEnglishResolveInstantly() {
        XCTAssertEqual(AppLanguage.resolve(mode: "en", systemLanguages: ["zh-Hans-CN"]), "en")
        XCTAssertEqual(AppLanguage.resolve(mode: "zh-Hans", systemLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["en-US"]), "en")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve(mode: "system", systemLanguages: ["zh-CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.brandName(language: "en"), "Ask Key")
        XCTAssertEqual(AppLanguage.brandName(language: "zh-Hans"), "请旨")
        XCTAssertEqual(AppLanguage.technicalName, "AskKey")
        XCTAssertEqual(AppLanguage.technicalCommand, "askkey")

        AppLanguage.current = "en"
        XCTAssertEqual(appLocalized("Ask Key"), "Ask Key")
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(appLocalized("Ask Key"), "请旨")
        XCTAssertEqual(appLocalized("Ask Key"), "请旨", "switching must not require a process restart")
    }

    func testManagementAuthenticationCopyMatchesTheSelectedLanguage() {
        XCTAssertEqual(
            AppLanguage.localized(CredentialManagementCopy.manageReason, language: "en"),
            "Confirm credential management"
        )
        XCTAssertEqual(
            AppLanguage.localized(CredentialManagementCopy.manageReason, language: "zh-Hans"),
            "请确认以管理凭证"
        )
        XCTAssertEqual(
            AppLanguage.localized(
                VaultError.managementAuthenticationRequired.localizedDescription,
                language: "zh-Hans"
            ),
            "需要确认后才能继续管理凭证。"
        )
        XCTAssertEqual(
            AppLanguage.localized("System authentication failed.", language: "zh-Hans"),
            "系统验证失败。"
        )
        let chineseReasons = [
            CredentialManagementCopy.revealReason: "确认查看凭证值",
            CredentialManagementCopy.pauseReason: "确认暂停 Agent 访问",
            CredentialManagementCopy.resumeReason: "确认恢复 Agent 访问",
            "Clear Ask Key access records": "确认清除请旨访问记录",
            "Erase the local Ask Key vault": "确认抹除请旨本机凭证库",
            "Restore Ask Key encrypted backup": "确认恢复请旨加密备份",
            "Create a new Ask Key backup namespace": "确认创建新的请旨备份空间",
            "Start Ask Key backup with the saved recovery key": "确认使用已保存的恢复密钥启动请旨备份",
            "Take ownership of Ask Key iCloud backup": "确认接管请旨 iCloud 备份",
            "Delete Ask Key iCloud backup": "确认删除请旨 iCloud 备份",
            "View the frozen file submitted for approval": "确认查看待批准的冻结文件内容",
            "Disable system authentication for read approvals": "关闭批准读取的系统验证",
        ]
        for (reason, expected) in chineseReasons {
            XCTAssertEqual(AppLanguage.localized(reason, language: "zh-Hans"), expected)
        }

        let approvalReasons: [(String, String)] = [
            (
                ManagementAuthenticationAction.approveRead.reasonKey,
                "授权 AI 助手使用所选凭证"
            ),
            (
                ManagementAuthenticationAction.approveWrite.reasonKey,
                "授权 AI 助手修改所选凭证"
            ),
        ]
        for (reasonKey, chineseReason) in approvalReasons {
            XCTAssertEqual(
                AppLanguage.table(language: "zh-Hans")[reasonKey],
                chineseReason
            )
            XCTAssertEqual(
                ManagementAuthenticationPresentation(
                    reasonKey: reasonKey,
                    language: "zh-Hans"
                ).reason,
                chineseReason
            )
            XCTAssertEqual(
                ManagementAuthenticationPresentation(
                    reasonKey: reasonKey,
                    language: "en"
                ).reason,
                reasonKey
            )
        }
    }

    func testBundleDisplayNameMatchesBrandInBothLanguages() throws {
        let resources = repoRoot().appendingPathComponent("Sources/AskKeyApp/Resources")
        let english = NSDictionary(
            contentsOf: resources.appendingPathComponent("en.lproj/InfoPlist.strings")
        ) as? [String: String]
        let chinese = NSDictionary(
            contentsOf: resources.appendingPathComponent("zh-Hans.lproj/InfoPlist.strings")
        ) as? [String: String]

        XCTAssertEqual(english?["CFBundleDisplayName"], "Ask Key")
        XCTAssertEqual(english?["CFBundleName"], "Ask Key")
        XCTAssertEqual(chinese?["CFBundleDisplayName"], "请旨")
        XCTAssertEqual(chinese?["CFBundleName"], "请旨")
    }

    func testCancellingChineseManagementAuthenticationStaysSilent() async {
        var presentation: ManagementAuthenticationPresentation?
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            authenticateDeviceOwner: { value in
                presentation = value
                return nil
            }
        )
        viewModel.languageMode = "zh-Hans"

        await viewModel.unlockForManagement()

        XCTAssertEqual(
            presentation,
            ManagementAuthenticationPresentation(
                reasonKey: CredentialManagementCopy.manageReason,
                language: "zh-Hans"
            )
        )
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testOnboardingCredentialCreationStartsWithoutSystemAuthentication() {
        var authenticationAttempts = 0
        var unlockAttempts = 0
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { unlockAttempts += 1 },
            authenticateDeviceOwner: { _ in
                authenticationAttempts += 1
                return .allow
            }
        )

        XCTAssertTrue(viewModel.beginOnboardingManagement())
        XCTAssertEqual(authenticationAttempts, 0)
        XCTAssertEqual(unlockAttempts, 1)
        XCTAssertFalse(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testIncompleteOnboardingWithExistingCredentialCanContinueAfterRestart() {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            storedCredentialCount: { 1 }
        )

        XCTAssertEqual(viewModel.settingsEntryState, .onboarding)
        XCTAssertEqual(viewModel.onboardingCredentialCount, 1)
        XCTAssertTrue(viewModel.credentials.isEmpty)
        viewModel.completeOnboarding(enableLaunchAtLogin: true)
        XCTAssertTrue(viewModel.hasCompletedOnboarding)
    }

    func testWindowAppearanceDoesNotInvokeManagementUnlock() throws {
        let root = repoRoot()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let popover = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/VaultPopover.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settings.contains("if vault.settingsEntryState == .locked { vault.unlock() }"))
        XCTAssertFalse(popover.contains("selectedIndex = 0\n            vault.unlock()"))
    }

    func testActiveLaunchShowsDockMenuBarAndMainWindow() {
        let event = launchEvent(loginItem: false)
        var policy: NSApplication.ActivationPolicy?
        var activationCount = 0
        var hiddenWindowCount = 0
        let presentation = AppLaunchPresentation.plan(for: AppLaunchSource(event: event))
        presentation.apply(
            setActivationPolicy: { policy = $0 },
            activateApplication: { activationCount += 1 },
            hideMainWindow: { hiddenWindowCount += 1 }
        )

        XCTAssertEqual(AppLaunchSource(event: event), .active)
        XCTAssertEqual(policy, .regular)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(hiddenWindowCount, 0)
    }

    func testPackagedMenuBarIconLoadsFromMainAppResources() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKey.icon.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Ask Key.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.sudohg.askkey.icon-test</string>
          <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.utf8).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(
            at: repoRoot().appendingPathComponent("Sources/AskKeyApp/Resources/MenuBarIcon.png"),
            to: resources.appendingPathComponent("MenuBarIcon.png")
        )

        let bundle = try XCTUnwrap(Bundle(url: app))
        let artwork = try XCTUnwrap(MenuBarIcon.artwork(in: bundle))
        XCTAssertGreaterThan(artwork.size.width, 0)
        XCTAssertGreaterThan(artwork.size.height, 0)
    }

    func testLoginItemLaunchKeepsOnlyTheMenuBarResident() {
        let event = launchEvent(loginItem: true)
        var policy: NSApplication.ActivationPolicy?
        var activationCount = 0
        var hiddenWindowCount = 0
        let presentation = AppLaunchPresentation.plan(for: AppLaunchSource(event: event))
        presentation.apply(
            setActivationPolicy: { policy = $0 },
            activateApplication: { activationCount += 1 },
            hideMainWindow: { hiddenWindowCount += 1 }
        )

        XCTAssertEqual(AppLaunchSource(event: event), .loginItem)
        XCTAssertEqual(policy, .accessory)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(hiddenWindowCount, 1)
    }

    private func launchEvent(loginItem: Bool) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if loginItem {
            event.setParam(
                NSAppleEventDescriptor(boolean: true),
                forKeyword: AEKeyword(keyAELaunchedAsLogInItem)
            )
        }
        return event
    }

    func testAgentApprovalUsesDirectConfirmationUnlessTheScreenIsLocked() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyApp/AskKeyApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("presentPendingApproval"))
        XCTAssertTrue(source.contains("AgentApprovalPrivacyPolicy"))
        XCTAssertTrue(source.contains("postLockedApprovalReminder"))
        XCTAssertFalse(source.contains("requestAuthorization(options: [.alert])"))
    }

    func testCredentialWorkspaceHasNoFolderAssociationAndGroupsOwnCreationActions() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/Views/CredentialManagementView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("folderAssociations"))
        XCTAssertFalse(source.contains("associateFolder"))
        XCTAssertFalse(source.contains("linkFolder"))
        XCTAssertTrue(source.contains("New group"))
        XCTAssertTrue(source.contains("Import from File"))
        XCTAssertFalse(source.contains("从文件导入到本组"))
        XCTAssertTrue(source.contains("CredentialComponentDraft(isOptional: true)"))
        XCTAssertTrue(source.contains("Authenticate and Replace"))
        XCTAssertTrue(source.contains("Recycle Bin"))
        let viewModelSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/VaultViewModel+Credentials.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(viewModelSource.contains("loadCredentialWorkspaceImpl"))
        let defaultAdapterSource = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyApp/VaultViewModel.swift"),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/CredentialWorkspaceMutations.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(workspaceSource.contains("purgeRecycledTextCredentials"))
        XCTAssertTrue(defaultAdapterSource.contains("credentialMutations.loadWorkspace"))
        XCTAssertFalse(defaultAdapterSource.contains("loadCredentialWorkspace:"))
        let appSource = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyApp/AskKeyApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appSource.contains("purgeExpiredRecycledCredentials"))
    }

    func testAgentClientsUsePlainLanguageAutomaticConnection() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/Views/CredentialManagementView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("AgentOnboardingView()"))
        XCTAssertFalse(source.contains("previewClient(.multica)"))
        XCTAssertFalse(source.contains("预览用户级配置差异"))
        XCTAssertFalse(source.contains("先看差异"))
        XCTAssertFalse(source.contains("Review the diff"))
        XCTAssertFalse(source.contains("reason: \"Connect \\(client.rawValue) to Ask Key\""))
        XCTAssertFalse(source.contains("MulticaSetupGuide"))
        XCTAssertFalse(source.contains("setString("))
        XCTAssertFalse(source.contains("Local Ask Key connection is healthy"))
        XCTAssertFalse(source.contains("{\"command\""))
        let onboardingSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/Views/AgentOnboardingView.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(onboardingSource.contains("onboarding.appear()"))
        XCTAssertTrue(onboardingSource.contains("Review connection"))
        XCTAssertTrue(onboardingSource.contains("Text(FrozenSettingsContract.agentAccessSubtitle)"))
        XCTAssertFalse(onboardingSource.contains("{\"command\""))
        let connectorSource = try String(
            contentsOf: repoRoot().appendingPathComponent(
                "Sources/AskKeyApp/AgentClientConnector.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(connectorSource.contains("redactedCursorDiff"))
        XCTAssertFalse(connectorSource.contains("\"command\""))

        XCTAssertTrue(AgentClient.multica.isAutomatic)
        XCTAssertFalse(AgentClient.multica.connectionPreviewSummary.contains("{"))
        XCTAssertFalse(AgentClient.multica.connectionPreviewSummary.contains("\"command\""))
    }

    func testCancellingKeychainAccessDoesNotShowAnErrorBanner() async {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { throw VaultError.keychainReadFailed(-128) },
            authenticateDeviceOwner: { _ in .allow }
        )
        viewModel.languageMode = "zh-Hans"

        await viewModel.unlockForManagement()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testCancellingInitialKeychainWriteDoesNotShowAnErrorBanner() async {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { throw VaultError.keychainWriteFailed(-128) },
            authenticateDeviceOwner: { _ in .allow }
        )
        viewModel.languageMode = "zh-Hans"

        await viewModel.unlockForManagement()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testKeychainFailuresUsePlainCopyInTheCurrentLanguage() async {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { throw VaultError.keychainReadFailed(-25293) },
            authenticateDeviceOwner: { _ in .allow }
        )

        viewModel.languageMode = "zh-Hans"
        await viewModel.unlockForManagement()
        XCTAssertEqual(viewModel.errorMessage, "请旨无法访问凭证库。请允许钥匙串访问后重试。")

        viewModel.languageMode = "en"
        await viewModel.unlockForManagement()
        XCTAssertEqual(
            viewModel.errorMessage,
            "Ask Key could not access the vault. Allow Keychain access, then try again."
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("security") == true)
        XCTAssertFalse(viewModel.errorMessage?.contains("-25293") == true)
    }

    func testVaultStorageFailureUsesTheCurrentLanguageThroughUnlock() async {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { throw VaultError.vaultStorageUnavailable },
            authenticateDeviceOwner: { _ in .allow }
        )

        viewModel.languageMode = "en"
        await viewModel.unlockForManagement()
        XCTAssertEqual(
            viewModel.errorMessage,
            "Ask Key could not open the local vault. Make sure the disk is available, then restart Ask Key. Existing data was not overwritten."
        )

        viewModel.languageMode = "zh-Hans"
        await viewModel.unlockForManagement()
        XCTAssertEqual(
            viewModel.errorMessage,
            "请旨无法打开本机凭证库。请确认磁盘可用并重启请旨；现有数据没有被覆盖。"
        )
    }

    func testMigrationKeychainFailuresUseTheSameCancellationAndCopyRules() async {
        var failure = MigrationKeyStoreError.securityFailure(-128)
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            unlockVault: { throw failure },
            authenticateDeviceOwner: { _ in .allow }
        )

        viewModel.languageMode = "zh-Hans"
        await viewModel.unlockForManagement()
        XCTAssertNil(viewModel.errorMessage)

        failure = .securityFailure(-25293)
        await viewModel.unlockForManagement()
        XCTAssertEqual(viewModel.errorMessage, "请旨无法访问凭证库。请允许钥匙串访问后重试。")
        XCTAssertFalse(viewModel.errorMessage?.contains("-25293") == true)
    }

    func testAuthenticationPresentationFollowsManualLanguageWithoutRestart() async {
        var presentations: [ManagementAuthenticationPresentation] = []
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            authenticateDeviceOwner: { presentation in
                presentations.append(presentation)
                return nil
            }
        )

        viewModel.languageMode = "zh-Hans"
        await viewModel.unlockForManagement()
        viewModel.languageMode = "en"
        await viewModel.unlockForManagement()

        XCTAssertEqual(presentations, [
            ManagementAuthenticationPresentation(
                reasonKey: CredentialManagementCopy.manageReason,
                language: "zh-Hans"
            ),
            ManagementAuthenticationPresentation(
                reasonKey: CredentialManagementCopy.manageReason,
                language: "en"
            ),
        ])
    }

    func testDynamicAuthenticationCopyUsesOneLanguageSnapshot() {
        AppLanguage.current = "zh-Hans"
        let presentation = ManagementAuthenticationPresentation.current(
            reason: "Unlock the AskKey vault for %@",
            arguments: { language in
                AppLanguage.current = "en"
                return [AppLanguage.localized("the AskKey CLI", language: language)]
            }
        )

        XCTAssertEqual(presentation.language, "zh-Hans")
        XCTAssertEqual(presentation.title, "请旨")
        XCTAssertEqual(presentation.reason, "为 AskKey 命令行 解锁请旨凭证库")
        XCTAssertEqual(AppLanguage.current, "en")
    }

    func testAuthenticationCancellationRequiresTheLAErrorDomain() {
        let cancellationCode = LAError.userCancel.rawValue
        XCTAssertEqual(
            ManagementAuthenticationOutcome.classify(
                NSError(domain: LAError.errorDomain, code: cancellationCode)
            ),
            .cancelled
        )
        XCTAssertEqual(
            ManagementAuthenticationOutcome.classify(
                NSError(domain: "unrelated.error", code: cancellationCode)
            ),
            .failed
        )
    }

    func testLockedFirstRunChoosesChineseOnboardingBeforeAuthentication() throws {
        var authenticationReasons: [String] = []
        let login = LoginItemProbe()
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            authenticateDeviceOwner: { presentation in
                authenticationReasons.append(presentation.reason)
                return nil
            }
        )
        viewModel.languageMode = "zh-Hans"

        XCTAssertEqual(viewModel.settingsEntryState, .onboarding)
        XCTAssertEqual(AppLanguage.localized("Open Ask Key", language: "zh-Hans"), "打开请旨")
        let screenshot = try renderPNG(
            SettingsView()
                .environment(viewModel)
                .environment(\.locale, viewModel.appLocale),
            size: CGSize(width: 1180, height: 720)
        )
        XCTAssertGreaterThan(screenshot.count, 8_000)
        XCTAssertTrue(authenticationReasons.isEmpty)
    }

    func testDailyEmptyAndProtectedLibrariesChooseDistinctEntryStates() async {
        let preferences = AppPreferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        var count = 0
        var authenticationAttempts = 0
        let viewModel = makeViewModel(
            preferences: preferences,
            login: LoginItemProbe(),
            storedCredentialCount: { count },
            authenticateDeviceOwner: { _ in
                authenticationAttempts += 1
                return .allow
            }
        )
        XCTAssertEqual(viewModel.settingsEntryState, .empty)
        XCTAssertEqual(authenticationAttempts, 0)
        count = 2
        viewModel.refreshCredentialSummary()
        XCTAssertEqual(viewModel.settingsEntryState, .locked)
        await viewModel.unlockForManagement()
        XCTAssertEqual(viewModel.settingsEntryState, .management)
        XCTAssertEqual(authenticationAttempts, 1)
        viewModel.lock()
        XCTAssertEqual(viewModel.settingsEntryState, .locked)
    }

    func testClosingManagementWindowRejectsLateAuthenticationAndAllowsFreshRetry() async {
        let preferences = AppPreferences(defaults: defaults)
        preferences.hasCompletedOnboarding = true
        var continuation: CheckedContinuation<ManagementAuthenticator?, Never>?
        var delayAuthentication = true
        var sessionStarts = 0
        var keyLoads = 0
        let started = expectation(description: "system authentication started")
        let viewModel = makeViewModel(
            preferences: preferences,
            login: LoginItemProbe(),
            unlockVault: { keyLoads += 1 },
            beginManagementSession: { _ in sessionStarts += 1 },
            storedCredentialCount: { 1 },
            authenticateDeviceOwner: { _ in
                guard delayAuthentication else { return .allow }
                return await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        )
        let pending = Task { await viewModel.unlockForManagement() }
        await fulfillment(of: [started], timeout: 2)
        ManagementSessionLifecycle { viewModel.endManagementSession() }
            .handle(.windowClosed(identifier: "settings"))
        continuation?.resume(returning: .allow)
        await pending.value
        XCTAssertEqual(keyLoads, 0)
        XCTAssertEqual(sessionStarts, 0)
        XCTAssertEqual(viewModel.settingsEntryState, .locked)

        delayAuthentication = false
        await viewModel.unlockForManagement()
        XCTAssertEqual(keyLoads, 1)
        XCTAssertEqual(sessionStarts, 1)
        XCTAssertEqual(viewModel.settingsEntryState, .management)
    }

    func testCancelledManagementAuthenticationCannotUnlockOnLateSuccess() async {
        var continuation: CheckedContinuation<ManagementAuthenticator?, Never>?
        let started = expectation(description: "system authentication started")
        var sessionStarts = 0
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: LoginItemProbe(),
            beginManagementSession: { _ in sessionStarts += 1 },
            authenticateDeviceOwner: { _ in
                await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        )
        let pending = Task { await viewModel.unlockForManagement() }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        continuation?.resume(returning: .allow)
        await pending.value
        XCTAssertEqual(sessionStarts, 0)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testLanguageModeSurvivesRelaunchAndCanRollBack() {
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.languageMode, "system")
        XCTAssertFalse(preferences.hasCompletedOnboarding)

        let login = LoginItemProbe()
        let first = makeViewModel(preferences: preferences, login: login)
        first.languageMode = "zh-Hans"
        XCTAssertEqual(first.brandName, "请旨")
        XCTAssertEqual(appLocalized("Ask Key"), "请旨")

        let relaunched = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login
        )
        XCTAssertEqual(relaunched.languageMode, "zh-Hans")
        XCTAssertEqual(relaunched.brandName, "请旨")

        relaunched.languageMode = "en"
        XCTAssertEqual(AppPreferences(defaults: defaults).languageMode, "en")
        XCTAssertEqual(relaunched.brandName, "Ask Key")
        XCTAssertEqual(appLocalized("Ask Key"), "Ask Key")
    }

    func testCatalogCoversBrandOnboardingLoginWarningNotificationsAndMenus() {
        for key in AppLanguage.requiredKeys {
            let english = AppLanguage.localized(key, language: "en")
            let chinese = AppLanguage.localized(key, language: "zh-Hans")
            XCTAssertFalse(english.isEmpty, "missing English value for \(key)")
            XCTAssertFalse(chinese.isEmpty, "missing Chinese value for \(key)")
            let keepEnglish = Set(["Codex", "Cursor", "Grok CLI", "English"])
            if !keepEnglish.contains(key) {
                XCTAssertNotEqual(chinese, key, "Chinese catalog still falls back to the English key \(key)")
            }
        }
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "en"), "Ask Key")
        XCTAssertEqual(AppLanguage.localized("AskKey", language: "zh-Hans"), "请旨")
        XCTAssertFalse(AppLanguage.localized("Ask Key", language: "en").contains("AskKey"))
        XCTAssertFalse(AppLanguage.localized("Ask Key", language: "zh-Hans").contains("AskKey"))
        XCTAssertFalse(AppLanguage.localized("Quit Ask Key", language: "zh-Hans").contains("AskKey"))
        XCTAssertTrue(
            AppLanguage.localized(
                "CLI and MCP cannot obtain credentials while Ask Key is not running.",
                language: "zh-Hans"
            ).contains("请旨未运行")
        )
    }

    func testKeyUIDoesNotHardcodeTechnicalBrandOrSkipRequiredCopy() throws {
        let root = repoRoot()
        let files = [
            "Sources/AskKeyApp/AskKeyApp.swift",
            "Sources/AskKeyApp/Views/CredentialManagementView.swift",
            "Sources/AskKeyApp/Views/VaultPopover.swift",
            "Sources/AskKeyApp/Views/SettingsView.swift",
            "Sources/AskKeyApp/Views/FirstRunOnboardingView.swift",
        ]
        for relative in files {
            let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(source.contains("Text(\"AskKey\")"), "\(relative) still uses technical AskKey as brand")
            XCTAssertFalse(source.contains("Window(\"AskKey\""), "\(relative) still titles the window AskKey")
            XCTAssertFalse(source.contains("Welcome to AskKey"), "\(relative) still greets with AskKey")
            XCTAssertFalse(source.contains("Quit AskKey"), "\(relative) still quits AskKey")
            XCTAssertFalse(source.contains("keep it in AskKey"), "\(relative) still mixes the technical name into UI copy")
        }

        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/FirstRunOnboardingView.swift"),
            encoding: .utf8
        )
        for needle in [
            "WorkspaceVisualContract.welcomeCopy",
            "Save access keys, login details, certificates, or a combination of them.",
            "Import a regular file or .env; the original file is not modified.",
            "One credential can contain multiple items",
            "Decide Agent requests immediately",
            "Ask Key runs in the background",
            "Launch at Login",
            "Create First Credential",
            "Start Using",
        ] {
            XCTAssertTrue(onboarding.contains(needle), "onboarding is missing \(needle)")
        }

        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/CredentialManagementView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(settings.contains("Language"))
        XCTAssertTrue(settings.contains("zh-Hans"))
        XCTAssertTrue(settings.contains("Launch at Login"))
        XCTAssertTrue(settings.contains("Timed Allow"))
        let language = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/AppLanguage.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(language.contains("Follow System"))
        XCTAssertTrue(language.contains("publishedModes"))

        let manager = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyApp/Views/SettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manager.contains("onboardingRoute = .fileImport"))
        XCTAssertTrue(manager.contains("FrozenTemplateChooserPage"))
    }

    func testDisablingLoginItemAppliesImmediatelyAndNeverTouchesTheRealLoginItemService() {
        let login = LoginItemProbe()
        login.enabled = true
        var appliedAllowance: [Int] = []
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login,
            updateTimedAllowance: { appliedAllowance.append($0) }
        )

        XCTAssertTrue(viewModel.launchAtLogin)
        viewModel.launchAtLogin = false
        XCTAssertEqual(login.setCalls, [false])
        XCTAssertFalse(viewModel.launchAtLogin)

        login.error = LoginItemProbeError.denied
        viewModel.launchAtLogin = true
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.launchAtLogin)
        XCTAssertEqual(login.setCalls, [false])

        viewModel.completeOnboarding(enableLaunchAtLogin: true)
        XCTAssertTrue(viewModel.hasCompletedOnboarding)
        XCTAssertTrue(AppPreferences(defaults: defaults).hasCompletedOnboarding)
        XCTAssertNotNil(viewModel.errorMessage)

        login.error = nil
        viewModel.hasCompletedOnboarding = false
        viewModel.completeOnboarding(enableLaunchAtLogin: true)
        XCTAssertEqual(login.setCalls, [false, true])
        XCTAssertTrue(viewModel.launchAtLogin)
        XCTAssertTrue(viewModel.hasCompletedOnboarding)

        viewModel.defaultTimedAllowanceMinutes = 15
        XCTAssertEqual(AppPreferences(defaults: defaults).defaultTimedAllowanceMinutes, 15)
        XCTAssertEqual(appliedAllowance, [15])
    }

    func testCompletingOnboardingWithLaunchAtLoginOffUnregistersAnExistingLoginItem() {
        let login = LoginItemProbe()
        login.enabled = true
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: login
        )

        viewModel.completeOnboarding(enableLaunchAtLogin: false)

        XCTAssertEqual(login.setCalls, [false])
        XCTAssertFalse(viewModel.launchAtLogin)
        XCTAssertTrue(viewModel.hasCompletedOnboarding)
        XCTAssertTrue(AppPreferences(defaults: defaults).hasCompletedOnboarding)
    }

    func testOnboardingAndSettingsRenderTheSameStateInBothLanguages() throws {
        let login = LoginItemProbe()
        let viewModel = makeViewModel(preferences: AppPreferences(defaults: defaults), login: login)
        viewModel.hasManagementSession = true
        viewModel.isLocked = false

        let directory = screenshotDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        viewModel.languageMode = "en"
        let englishOnboarding = try renderPNG(
            FirstRunOnboardingView(onCreateCredential: {}, onImportCredential: {})
                .environment(viewModel)
                .environment(\.locale, viewModel.appLocale),
            size: CGSize(width: 720, height: 780)
        )
        let englishSettings = try renderPNG(
            FrozenSettingsPage()
                .environment(viewModel)
                .environment(\.locale, viewModel.appLocale),
            size: CGSize(width: 776, height: 620)
        )

        viewModel.languageMode = "zh-Hans"
        let chineseOnboarding = try renderPNG(
            FirstRunOnboardingView(onCreateCredential: {}, onImportCredential: {})
                .environment(viewModel)
                .environment(\.locale, viewModel.appLocale),
            size: CGSize(width: 720, height: 780)
        )
        let chineseSettings = try renderPNG(
            FrozenSettingsPage()
                .environment(viewModel)
                .environment(\.locale, viewModel.appLocale),
            size: CGSize(width: 776, height: 620)
        )

        try writePNG(englishOnboarding, to: directory.appendingPathComponent("onboarding-en.png"))
        try writePNG(chineseOnboarding, to: directory.appendingPathComponent("onboarding-zh-Hans.png"))
        try writePNG(englishSettings, to: directory.appendingPathComponent("settings-en.png"))
        try writePNG(chineseSettings, to: directory.appendingPathComponent("settings-zh-Hans.png"))

        XCTAssertGreaterThan(englishOnboarding.count, 8_000)
        XCTAssertGreaterThan(chineseOnboarding.count, 8_000)
        XCTAssertGreaterThan(englishSettings.count, 8_000)
        XCTAssertGreaterThan(chineseSettings.count, 8_000)
        XCTAssertNotEqual(englishOnboarding, chineseOnboarding)
        XCTAssertNotEqual(englishSettings, chineseSettings)
    }

    func testOnboardingCopyHasNoSecretsAndTechnicalIdentifiersStayUntranslated() {
        let chinese = AppLanguage.table(language: "zh-Hans")
        for (key, value) in chinese {
            XCTAssertFalse(value.contains("sk-"), "catalog leaked a secret-like token in \(key)")
            XCTAssertFalse(value.contains("AKIA"), "catalog leaked a secret-like token in \(key)")
            XCTAssertFalse(value.contains("-----BEGIN"), "catalog leaked a private key in \(key)")
        }
        XCTAssertEqual(AppLanguage.technicalName, "AskKey")
        XCTAssertEqual(AppLanguage.technicalCommand, "askkey")
        XCTAssertEqual(chinese["Codex"], "Codex")
        XCTAssertEqual(chinese["Cursor"], "Cursor")
        XCTAssertEqual(chinese["Grok CLI"], "Grok CLI")
    }

    private func makeViewModel(
        preferences: AppPreferences,
        login: LoginItemProbe,
        unlockVault: @escaping () throws -> Void = {},
        beginManagementSession: @escaping (ManagementAuthenticator) throws -> Void = { _ in },
        beginOnboardingManagementSession: @escaping () throws -> Void = {},
        storedCredentialCount: @escaping () throws -> Int = { 0 },
        authenticateDeviceOwner: (@MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticator?)? = nil,
        updateTimedAllowance: @escaping (Int) -> Void = { _ in }
    ) -> VaultViewModel {
        VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            inspectICloudBackup: { _ in [] },
            listICloudBackupConflicts: { _ in [] },
            restoreICloudBackup: { _, _, _ in
                throw ICloudBackupError.containerUnavailable
            },
            takeOwnershipOfICloudBackup: { _, _, _ in },
            deleteICloudBackup: { _, _ in },
            listICloudBackupNamespaces: { [] },
            createICloudBackupNamespace: { _ in "unused" },
            activateICloudBackupNamespace: { _, _ in
                throw ICloudBackupError.containerUnavailable
            },
            unlockVault: unlockVault,
            beginManagementSession: beginManagementSession,
            beginOnboardingManagementSession: beginOnboardingManagementSession,
            authenticateDeviceOwner: authenticateDeviceOwner,
            preferences: preferences,
            loginItem: login.controller(),
            updateTimedAllowance: updateTimedAllowance,
            credentialMutations: CredentialWorkspaceMutations.readOnly { ([], [], [], false) }
                .counting(storedCredentialCount)
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func screenshotDirectory() -> URL {
        repoRoot()
            .deletingLastPathComponent()
            .appendingPathComponent("screenshots", isDirectory: true)
    }

    private func renderPNG<V: View>(_ view: V, size: CGSize) throws -> Data {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw ScreenshotError.noRepresentation
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.noPNG
        }
        return data
    }

    private func writePNG(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }
}

private enum ScreenshotError: Error {
    case noRepresentation
    case noPNG
}

private enum LoginItemProbeError: Error {
    case denied
}

private final class LoginItemProbe: @unchecked Sendable {
    private let lock = NSLock()
    var enabled = false
    var setCalls: [Bool] = []
    var error: Error?

    func controller() -> LoginItemController {
        LoginItemController(
            isEnabled: { [weak self] in
                guard let self else { return false }
                self.lock.lock(); defer { self.lock.unlock() }
                return self.enabled
            },
            setEnabled: { [weak self] value in
                guard let self else { return }
                self.lock.lock(); defer { self.lock.unlock() }
                if let error = self.error { throw error }
                self.setCalls.append(value)
                self.enabled = value
            }
        )
    }
}
