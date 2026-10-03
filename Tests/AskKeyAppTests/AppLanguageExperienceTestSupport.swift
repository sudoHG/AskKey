import AppKit
import CoreServices
import LocalAuthentication
import SwiftUI
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyVault

@MainActor
class AppLanguageExperienceTestSupport: AskKeyAppTestCase {
    private var suiteName = ""
    var defaults: UserDefaults!

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

    func launchEvent(loginItem: Bool) -> NSAppleEventDescriptor {
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

    func makeViewModel(
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

    func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func renderPNG<V: View>(_ view: V, size: CGSize) throws -> Data {
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

    func writePNG(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    enum ScreenshotError: Error {
        case noRepresentation
        case noPNG
    }

    enum LoginItemProbeError: Error {
        case denied
    }

    final class LoginItemProbe: @unchecked Sendable {
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
}
