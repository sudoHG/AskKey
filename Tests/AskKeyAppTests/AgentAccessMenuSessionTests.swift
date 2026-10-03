import AppKit
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

@MainActor
final class AgentAccessMenuSessionTests: AskKeyAppTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AskKey.pause.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMenuPauseWorksWhileManagementIsLockedAndDoesNotOpenASession() async {
        var paused = false
        var pauseCalls = 0
        var sessionStarts = 0
        let viewModel = makeViewModel(
            storedCredentialCount: { 2 },
            authenticateDeviceOwner: { _ in .allow },
            beginManagementSession: { _ in sessionStarts += 1 },
            isAgentAccessPaused: { paused },
            pauseAgentAccess: { _ in
                pauseCalls += 1
                paused = true
            }
        )
        viewModel.completeOnboarding(enableLaunchAtLogin: false)

        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
        await viewModel.pauseAgentAccess()

        XCTAssertEqual(pauseCalls, 1)
        XCTAssertTrue(viewModel.isAgentAccessPaused)
        XCTAssertFalse(viewModel.hasManagementSession)
        XCTAssertEqual(sessionStarts, 0)
        XCTAssertEqual(viewModel.settingsEntryState, .locked)
    }

    func testResumeAuthenticationCancelLeavesAccessPausedAndManagementLocked() async {
        var paused = true
        var resumeCalls = 0
        let viewModel = makeViewModel(
            storedCredentialCount: { 1 },
            authenticateDeviceOwner: { _ in nil },
            isAgentAccessPaused: { paused },
            resumeAgentAccess: { _ in
                resumeCalls += 1
                paused = false
            }
        )
        viewModel.isAgentAccessPaused = true

        await viewModel.resumeAgentAccess()

        XCTAssertEqual(resumeCalls, 0)
        XCTAssertTrue(viewModel.isAgentAccessPaused)
        XCTAssertFalse(viewModel.hasManagementSession)
        XCTAssertTrue(viewModel.isLocked)
    }

    func testSuccessfulResumeDoesNotUnlockManagement() async {
        var paused = true
        let viewModel = makeViewModel(
            storedCredentialCount: { 1 },
            authenticateDeviceOwner: { _ in .allow },
            isAgentAccessPaused: { paused },
            resumeAgentAccess: { _ in paused = false }
        )
        viewModel.completeOnboarding(enableLaunchAtLogin: false)
        viewModel.isAgentAccessPaused = true

        await viewModel.resumeAgentAccess()

        XCTAssertFalse(viewModel.isAgentAccessPaused)
        XCTAssertFalse(viewModel.hasManagementSession)
        XCTAssertTrue(viewModel.isLocked)
        XCTAssertEqual(viewModel.settingsEntryState, .locked)
    }

    func testRefreshSyncsPauseStateWhileManagementIsLocked() {
        let viewModel = makeViewModel(
            storedCredentialCount: { 3 },
            isAgentAccessPaused: { true }
        )

        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.isAgentAccessPaused)
        viewModel.refresh()
        XCTAssertTrue(viewModel.isAgentAccessPaused)
        XCTAssertTrue(viewModel.credentials.isEmpty)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    func testEmptyOnboardingIdleShowsLockedWorkbenchWithoutClosingWindows() {
        let viewModel = makeViewModel(storedCredentialCount: { 0 })
        viewModel.sessionTimeoutSeconds = 0.05

        XCTAssertEqual(viewModel.settingsEntryState, .onboarding)
        XCTAssertTrue(viewModel.beginOnboardingManagement())
        XCTAssertFalse(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)

        let expired = expectation(description: "onboarding idle lock")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertTrue(viewModel.isLocked)
            XCTAssertFalse(viewModel.hasManagementSession)
            XCTAssertTrue(viewModel.credentials.isEmpty)
            XCTAssertEqual(viewModel.settingsEntryState, .locked)
            expired.fulfill()
        }
        wait(for: [expired], timeout: 1)
    }

    func testManagementIdleKeepsWindowStateAsLockedWorkbench() async {
        let viewModel = makeViewModel(
            storedCredentialCount: { 2 },
            authenticateDeviceOwner: { _ in .allow },
            managementSessionIdleLimit: 0.05
        )
        viewModel.completeOnboarding(enableLaunchAtLogin: false)
        await viewModel.unlockForManagement()
        XCTAssertEqual(viewModel.settingsEntryState, .management)

        let expired = expectation(description: "management idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            XCTAssertFalse(viewModel.hasManagementSession)
            XCTAssertEqual(viewModel.settingsEntryState, .locked)
            expired.fulfill()
        }
        await fulfillment(of: [expired], timeout: 1)
    }

    func testLockDoesNotCloseVisibleWindows() throws {
        let source = try String(
            contentsOf: repoRoot().appendingPathComponent("Sources/AskKeyApp/VaultViewModel.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("closeVisibleSurfaces"),
            "Idle lock must keep the management window on the locked workbench."
        )
    }

    private func makeViewModel(
        storedCredentialCount: @escaping () throws -> Int,
        authenticateDeviceOwner: (@MainActor (ManagementAuthenticationPresentation) async -> ManagementAuthenticator?)? = nil,
        beginManagementSession: @escaping (ManagementAuthenticator) throws -> Void = { _ in },
        isAgentAccessPaused: @escaping () throws -> Bool = { false },
        pauseAgentAccess: @escaping (ManagementAuthenticator) throws -> Void = { _ in },
        resumeAgentAccess: @escaping (ManagementAuthenticator) throws -> Void = { _ in },
        managementSessionIdleLimit: TimeInterval = Vault.managementSessionIdleLimit
    ) -> VaultViewModel {
        VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: beginManagementSession,
            beginOnboardingManagementSession: {},
            authenticateDeviceOwner: authenticateDeviceOwner,
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            managementSessionIdleLimit: managementSessionIdleLimit,
            isAgentAccessPaused: isAgentAccessPaused,
            pauseAgentAccess: pauseAgentAccess,
            resumeAgentAccess: resumeAgentAccess,
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
}
