import Foundation
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

    func testUpdateCopyIsTranslatedWithCatalogTerms() {
        let copy = [
            "Check for Updates…": "检查更新…",
            "Check for Updates Automatically": "自动检查更新",
            "Updates": "更新",
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
        XCTAssertTrue(relaunch.contains("限时允许"))
    }
}
