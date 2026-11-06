import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import AskKeyAppKit

@MainActor
final class SoftwareUpdateControlsTests: XCTestCase {
    private final class FakeUpdater: SoftwareUpdater {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = false
        var checks = 0
        var changeHandler: (@MainActor () -> Void)?

        func checkForUpdates() { checks += 1 }
        func observeChanges(_ handler: @escaping @MainActor () -> Void) { changeHandler = handler }
    }

    func testControlsMirrorTheUpdaterAndFollowItsChanges() {
        let updater = FakeUpdater()
        let controls = SoftwareUpdateControls(updater: updater)
        XCTAssertTrue(controls.canCheckForUpdates)
        XCTAssertFalse(controls.automaticallyChecksForUpdates)

        updater.canCheckForUpdates = false
        updater.automaticallyChecksForUpdates = true
        updater.changeHandler?()
        XCTAssertFalse(controls.canCheckForUpdates)
        XCTAssertTrue(controls.automaticallyChecksForUpdates)
    }

    func testAutomaticCheckSwitchWritesTheUpdaterSetting() {
        let updater = FakeUpdater()
        let controls = SoftwareUpdateControls(updater: updater)
        controls.setAutomaticallyChecksForUpdates(true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        XCTAssertTrue(controls.automaticallyChecksForUpdates)
        controls.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testCheckNowRunsOnlyWhenTheUpdaterCanCheck() {
        let updater = FakeUpdater()
        let controls = SoftwareUpdateControls(updater: updater)
        controls.checkForUpdates()
        XCTAssertEqual(updater.checks, 1)

        updater.canCheckForUpdates = false
        controls.checkForUpdates()
        XCTAssertEqual(updater.checks, 1)
    }

    func testPopoverListsCheckForUpdatesOnlyWithAnUpdaterAndDisablesItWhileBusy() throws {
        let suite = "SoftwareUpdatePopover-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        let vault = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            authenticateDeviceOwner: { _ in .authenticated(.allow) },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { true }, setEnabled: { _ in }),
            agentAccessPolicyOperations: AgentAccessPolicyTestState().operations,
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        let withoutUpdater = try renderPopover(vault)

        let updater = FakeUpdater()
        vault.softwareUpdates = SoftwareUpdateControls(updater: updater)
        let enabled = try renderPopover(vault)
        XCTAssertEqual(enabled.size.width, withoutUpdater.size.width)
        XCTAssertEqual(enabled.size.height - withoutUpdater.size.height, 30, "Only an updater adds the one row")

        updater.canCheckForUpdates = false
        updater.changeHandler?()
        let busy = try renderPopover(vault)
        XCTAssertEqual(busy.size, enabled.size, "A check in progress keeps the row")
        XCTAssertNotEqual(busy.png, enabled.png, "A check in progress shows the row disabled")

        updater.canCheckForUpdates = true
        updater.changeHandler?()
        XCTAssertEqual(try renderPopover(vault).png, enabled.png, "The row is enabled again after the check")
    }

    /// Renders the real popover in a window that is never ordered in.
    private func renderPopover(_ vault: VaultViewModel) throws -> (size: CGSize, png: Data) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: VaultPopover(onOpenManagement: {
            XCTFail("Rendering must not open management")
        }).environment(vault))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        for _ in 0..<4 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return (size, try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
    }

    func testUpdateCopyIsTranslatedWithCatalogTerms() {
        let copy = [
            "Check for Updates…": "检查更新…", // i18n-literal: Chinese catalog assertion
            "Check for Updates Automatically": "自动检查更新", // i18n-literal: Chinese catalog assertion
            "Updates": "更新", // i18n-literal: Chinese catalog assertion
        ]
        for (english, chinese) in copy {
            XCTAssertEqual(AppLanguage.localized(english, language: "en"), english)
            XCTAssertEqual(AppLanguage.localized(english, language: "zh-Hans"), chinese)
        }
        let relaunch = AppLanguage.localized(
            "Installing an update relaunches Ask Key once no request is waiting or running. Ask Key then locks again, and timed allowances end.",
            language: "zh-Hans"
        )
        XCTAssertTrue(relaunch.contains("请旨"))
        XCTAssertTrue(relaunch.contains("限时允许")) // i18n-literal: Chinese catalog assertion
    }
}
