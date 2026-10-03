import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class OnboardingFlowTests: AppLanguageExperienceTestSupport {
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

        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyLanguageUI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
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
}
