import XCTest

/// Required: the runner's real click on Settings → Devices → Pair a Device….
/// On macOS 26 the button took no clicks while the Devices box held a single
/// row; the empty list row keeps a second row there (#299). A regression
/// fails this flow instead of only the optional screenshots (#301).
final class DevicesE2ETests: E2EBaseCase {
    /// The runner's click on Pair a Device… opens the sheet, on every macOS release (#299).
    func testPairADeviceOpensItsSheet() throws {
        _ = openDevicesSettings(language: "en")
        click("settings-pair-device")
        XCTAssertTrue(app.windows["settings"].sheets.firstMatch.waitForExistence(timeout: 8), "Pair a Device… opened no sheet")
    }
}

extension E2EBaseCase {
    /// Settings on the E2E App's fake device services (#288), Pair a Device… in view.
    func openDevicesSettings(language: String) -> XCUIElement {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "screenshots-devices"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = language
        app.launch()
        addTeardownBlock { [app] in app?.terminate() } // a hung query must not also hang the teardown
        moveManagementAboveDock()
        click("unlock-management")
        click("sidebar-settings")
        let page = app.scrollViews["settings-page"].firstMatch
        let pair = app.buttons["settings-pair-device"].firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 8))
        for _ in 0..<6 where !pair.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        return page
    }
}
