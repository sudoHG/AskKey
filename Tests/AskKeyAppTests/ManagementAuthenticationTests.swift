import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class ManagementAuthenticationTests: AppLanguageExperienceTestSupport {
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

    func testWindowAppearanceDoesNotInvokeManagementUnlock() throws {
        let root = repoRoot()
        let settings = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let popover = try String(
            contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/Views/VaultPopover.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settings.contains("if vault.settingsEntryState == .locked { vault.unlock() }"))
        XCTAssertFalse(popover.contains("selectedIndex = 0\n            vault.unlock()"))
    }

    func testAgentApprovalUsesDirectConfirmationUnlessTheScreenIsLocked() throws {
        let source = try AskKeyAppSource.read(from: repoRoot())

        XCTAssertTrue(source.contains("presentPendingApproval"))
        XCTAssertTrue(source.contains("AgentApprovalPrivacyPolicy"))
        XCTAssertTrue(source.contains("postLockedApprovalReminder"))
        XCTAssertFalse(source.contains("requestAuthorization(options: [.alert])"))
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
        var failure = AppKeyStoreError.securityFailure(-128)
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
        XCTAssertEqual(presentation.reason, "为 Ask Key 命令行 解锁请旨凭证库")
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
}
