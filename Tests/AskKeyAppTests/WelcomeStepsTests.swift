import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
final class WelcomeStepsTests: AppLanguageExperienceTestSupport {
    func testFirstOpenEmphasizesOnlyTheStoreStep() {
        let steps = WelcomeStepsPresentation(storedCredentialCount: 0, savedCredential: nil)

        XCTAssertEqual(steps.steps.map(\.state), [.current, .upcoming, .upcoming])
        XCTAssertEqual(
            steps.steps.map(\.title),
            ["Store a credential", "Connect your Agent", "Try it once"]
        )
        XCTAssertFalse(steps.isConnectingAgent)
    }

    func testFirstSaveMarksStepOneDoneAndMakesConnectingCurrent() {
        AppLanguage.current = "zh-Hans"
        let steps = WelcomeStepsPresentation(
            storedCredentialCount: 1,
            savedCredential: .init(name: "demo-api", permission: .ask)
        )

        XCTAssertEqual(steps.steps.map(\.state), [.done, .current, .upcoming])
        XCTAssertEqual(steps.steps[0].title, "已保存 demo-api") // i18n-literal: Simplified Chinese welcome copy
        XCTAssertEqual(steps.steps[0].message, "权限：每次询问。可以在“全部凭证”里修改。") // i18n-literal: Simplified Chinese welcome copy
        XCTAssertEqual(steps.steps[1].title, "接入你的 Agent") // i18n-literal: Simplified Chinese welcome copy
        XCTAssertTrue(steps.isConnectingAgent)
    }

    func testSavedStepNamesTheChosenPermission() {
        let allowed = WelcomeStepsPresentation(
            storedCredentialCount: 1,
            savedCredential: .init(name: "deploy", permission: .allowed)
        )
        let hidden = WelcomeStepsPresentation(
            storedCredentialCount: 1,
            savedCredential: .init(name: "deploy", permission: .hidden)
        )

        XCTAssertEqual(allowed.steps[0].title, "Saved deploy")
        XCTAssertEqual(allowed.steps[0].message, "Permission: Allow. You can change it in All credentials.")
        XCTAssertEqual(hidden.steps[0].message, "Permission: Hidden. You can change it in All credentials.")
    }

    func testRelaunchBeforeFinishingKeepsStepTwoCurrentWithoutTheName() {
        let steps = WelcomeStepsPresentation(storedCredentialCount: 1, savedCredential: nil)

        XCTAssertEqual(steps.steps.map(\.state), [.done, .current, .upcoming])
        XCTAssertEqual(steps.steps[0].title, "First credential saved")
        XCTAssertEqual(steps.steps[0].message, "Review it in All credentials.")
    }

    func testViewModelRemembersTheFirstSaveUntilOnboardingCompletes() {
        var count = 0
        var mutations = CredentialWorkspaceMutations.readOnly { ([], [], [], false) }
            .counting { count }
        mutations.createBundle = { _ in count += 1 }
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            beginOnboardingManagementSession: {},
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemProbe().controller(),
            credentialMutations: mutations
        )

        XCTAssertTrue(viewModel.beginOnboardingManagement())
        XCTAssertTrue(viewModel.addBundleCredential(.init(
            name: "demo-api",
            components: [],
            permission: .hidden
        )))
        XCTAssertEqual(viewModel.onboardingCredentialCount, 1)
        XCTAssertEqual(viewModel.settingsEntryState, .onboarding)
        XCTAssertEqual(
            viewModel.onboardingSavedCredential,
            .init(name: "demo-api", permission: .hidden)
        )

        viewModel.completeOnboarding(enableLaunchAtLogin: false)
        XCTAssertNil(viewModel.onboardingSavedCredential)
        XCTAssertEqual(viewModel.settingsEntryState, .locked)

        XCTAssertTrue(viewModel.addBundleCredential(.init(name: "later", components: [])))
        XCTAssertNil(viewModel.onboardingSavedCredential)
    }

    func testConnectAgentOpensAgentAccessBehindTheManagementLock() throws {
        let settings = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyAppKit/Views/SettingsView.swift"),
            encoding: .utf8
        )
        let wiring = try XCTUnwrap(settings.range(of: "onConnectAgent: {"))
        let body = String(settings[wiring.upperBound...].prefix(400))
        XCTAssertTrue(body.contains("workspaceRoute = .agentAccess"))
        XCTAssertTrue(body.contains("vault.unlock()"))
    }

    func testBothWelcomeStatesRenderInBothLanguages() throws {
        let viewModel = makeViewModel(
            preferences: AppPreferences(defaults: defaults),
            login: LoginItemProbe()
        )
        var renders: [Data] = []
        for language in ["en", "zh-Hans"] {
            viewModel.languageMode = language
            for saved in [false, true] {
                viewModel.onboardingCredentialCount = saved ? 1 : 0
                viewModel.onboardingSavedCredential = saved
                    ? .init(name: "demo-api", permission: .ask)
                    : nil
                renders.append(try renderPNG(
                    FirstRunOnboardingView(onCreateCredential: {}, onImportCredential: {})
                        .environment(viewModel)
                        .environment(\.locale, viewModel.appLocale),
                    size: CGSize(width: 776, height: 620)
                ))
            }
        }
        for render in renders { XCTAssertGreaterThan(render.count, 8_000) }
        XCTAssertEqual(Set(renders).count, renders.count)
    }
}
