import AppKit
import SwiftUI
import XCTest
@testable import AskKeyApp
import AskKeyCore

final class ManagementWorkspaceNavigationTests: XCTestCase {
    @MainActor
    func testLockedWorkspaceSidebarSelectsRoutesWithoutAuthentication() async {
        for destination in [
            CredentialWorkspaceRoute.accessRecords,
            .agentAccess,
            .settings,
        ] {
            var authenticationAttempts = 0
            let viewModel = makeViewModel {
                authenticationAttempts += 1
                return .allow
            }
            var section = CredentialWorkspaceSection.all
            var route = CredentialWorkspaceRoute.library
            let sidebar = CredentialWorkspaceSidebar(
                selectedSection: Binding(get: { section }, set: { section = $0 }),
                route: Binding(get: { route }, set: { route = $0 }),
                allowsCredentialChanges: false
            )

            sidebar.selectRoute(destination)
            XCTAssertEqual(route, destination)
            XCTAssertEqual(route.sidebarSelection, destination.sidebarSelection)
            XCTAssertEqual(authenticationAttempts, 0)

            await viewModel.unlockForManagement()
            XCTAssertEqual(authenticationAttempts, 1)
            XCTAssertEqual(viewModel.settingsEntryState, .management)
            XCTAssertEqual(route, destination)
        }
    }

    @MainActor
    func testSidebarGroupRowSelectsFromTrailingBlankSpace() throws {
        var section = CredentialWorkspaceSection.all
        var route = CredentialWorkspaceRoute.library
        let sidebar = CredentialWorkspaceSidebar(
            selectedSection: Binding(get: { section }, set: { section = $0 }),
            route: Binding(get: { route }, set: { route = $0 }),
            allowsCredentialChanges: false
        )
        let window = try makeSidebarWindow(sidebar)
        defer { window.orderOut(nil) }

        for y in stride(from: 300.0, through: 620.0, by: 2.0) {
            try click(at: NSPoint(x: 190, y: y), in: window)
            if section == .ungrouped { break }
        }

        XCTAssertEqual(section, .ungrouped)
        XCTAssertEqual(route, .library)
    }

    @MainActor
    func testSidebarRouteRowSelectsFromTrailingBlankSpace() throws {
        var section = CredentialWorkspaceSection.all
        var route = CredentialWorkspaceRoute.library
        let sidebar = CredentialWorkspaceSidebar(
            selectedSection: Binding(get: { section }, set: { section = $0 }),
            route: Binding(get: { route }, set: { route = $0 }),
            allowsCredentialChanges: false
        )
        let window = try makeSidebarWindow(sidebar)
        defer { window.orderOut(nil) }

        for y in stride(from: 0.0, through: 300.0, by: 2.0) {
            try click(at: NSPoint(x: 190, y: y), in: window)
            if route == .settings { break }
        }

        XCTAssertEqual(route, .settings)
        XCTAssertEqual(section, .all)
    }

    @MainActor
    func testManagementActivityDoesNotScheduleVaultLock() async throws {
        let viewModel = makeViewModel { nil }
        viewModel.isLocked = false
        viewModel.hasManagementSession = true
        viewModel.sessionTimeoutSeconds = 0.01

        viewModel.renewSession()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(viewModel.isLocked)
        XCTAssertTrue(viewModel.hasManagementSession)
    }

    @MainActor
    func testUnlockingManagementDoesNotScheduleVaultLock() async throws {
        let viewModel = makeViewModel { .allow }
        viewModel.sessionTimeoutSeconds = 0.01

        await viewModel.unlockForManagement()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(viewModel.isLocked)
        XCTAssertTrue(viewModel.hasManagementSession)
    }

    @MainActor
    func testExistingVaultTimerCannotLockAnActiveManagementSession() async throws {
        let viewModel = makeViewModel { nil }
        viewModel.isLocked = false
        viewModel.sessionTimeoutSeconds = 0.01
        viewModel.renewSession()
        viewModel.hasManagementSession = true

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(viewModel.isLocked)
        XCTAssertTrue(viewModel.hasManagementSession)
    }

    @MainActor
    func testVisualProofStartsAtTheLockedWorkspace() {
        let previous = ProcessInfo.processInfo.environment["ASKKEY_VISUAL_PROOF"]
        setenv("ASKKEY_VISUAL_PROOF", "1", 1)
        defer {
            if let previous {
                setenv("ASKKEY_VISUAL_PROOF", previous, 1)
            } else {
                unsetenv("ASKKEY_VISUAL_PROOF")
            }
        }
        let viewModel = AppRuntimeState.makeVaultViewModel()

        XCTAssertTrue(viewModel.isLocked)
        XCTAssertFalse(viewModel.hasManagementSession)
    }

    @MainActor
    func testManagementIdleExpiryLeavesTheVaultUnlocked() async throws {
        let viewModel = makeViewModel(authenticate: { nil }, managementSessionIdleLimit: 0.01)
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        viewModel.renewManagementSession()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while viewModel.hasManagementSession,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(viewModel.hasManagementSession)
        XCTAssertFalse(viewModel.isLocked)
    }

    @MainActor
    private func makeViewModel(
        authenticate: @escaping @MainActor () -> ManagementAuthenticator?,
        managementSessionIdleLimit: TimeInterval = Vault.managementSessionIdleLimit
    ) -> VaultViewModel {
        let defaults = UserDefaults(suiteName: "ManagementWorkspaceNavigationTests-\(UUID())")
            ?? .standard
        defaults.set(true, forKey: "hasCompletedOnboarding")
        return VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            unlockVault: {},
            beginManagementSession: { _ in },
            authenticateDeviceOwner: { _ in authenticate() },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { false }, setEnabled: { _ in }),
            managementSessionIdleLimit: managementSessionIdleLimit,
            credentialMutations: .readOnly { ([], [], [], false) }
        )
    }

    @MainActor
    private func makeSidebarWindow(_ sidebar: CredentialWorkspaceSidebar) throws -> NSWindow {
        _ = NSApplication.shared
        let size = CGSize(width: 204, height: 620)
        let hosting = NSHostingView(rootView: sidebar.environment(makeViewModel { nil }))
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        guard window.windowNumber > 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return window
    }

    @MainActor
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let screenPoint = window.convertPoint(toScreen: point)
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: screenPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: screenPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            throw NSError(domain: "ManagementWorkspaceNavigationTests", code: 1)
        }
        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

}
