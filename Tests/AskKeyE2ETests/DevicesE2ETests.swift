import XCTest

/// Required: the runner's real clicks on Settings → Devices. On macOS 26
/// Pair a Device… took no clicks while the Devices box held a single row;
/// the empty list row keeps a second row there (#299). A regression fails
/// these flows instead of only the optional screenshots (#301, #313).
final class DevicesE2ETests: E2EBaseCase {
    /// The runner's click on Pair a Device… opens the sheet, on every macOS release (#299).
    func testPairADeviceOpensItsSheet() throws {
        _ = openDevicesSettings(language: "en")
        click("settings-pair-device")
        XCTAssertTrue(app.windows["settings"].sheets.firstMatch.waitForExistence(timeout: 8), "Pair a Device… opened no sheet")
    }

    /// Pairing makes the iPhone an approver (#336): with exactly one paired
    /// iPhone, its row says it approves agent requests, and the runner's real
    /// clicks on **Remove** and its confirmation, the Mac's only way to stop
    /// an iPhone approving, take the row away (#299, #300).
    func testPairedIPhoneApprovesAgentRequestsUntilRemoved() throws {
        let page = openDevicesSettings(language: "en")
        pairSyntheticIPhone(page: page)
        page.scroll(byDeltaX: 0, deltaY: -900) // the whole row in view
        waitUntilShown("devices-row-approval", "Can approve agent requests.")
        clickInPage("devices-remove", page: page)
        clickInPage("devices-confirm-remove", page: page)
        let rename = app.buttons["devices-rename"].firstMatch
        let gone = NSPredicate { _, _ in !rename.exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8), .completed,
                       "the removed iPhone is still listed")
        XCTAssertTrue(app.staticTexts["settings-devices-empty"].firstMatch.waitForExistence(timeout: 8), "No empty list row")
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

    /// Runs a fixture command of the device scenario and checks that it succeeded.
    func deviceFixture(_ command: String, file: StaticString = #filePath, line: UInt = #line) throws {
        try sendFixtureCommand(command)
        XCTAssertEqual(try waitForEvidence("device-\(command).json")["ok"] as? Bool, true, command, file: file, line: line)
    }

    /// Waits until the static text `identifier` shows `text`. Texts are found
    /// by identifier: after a field had focus, whole-window snapshots can
    /// hang on the cursor's remote element in CI.
    func waitUntilShown(_ identifier: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts[identifier].firstMatch
        let shown = NSPredicate { _, _ in element.exists && (element.label.contains(text) || (element.value as? String)?.contains(text) == true) }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 8), .completed,
                       "Missing \(text)", file: file, line: line)
    }

    /// The runner clicks Pair a Device…; the fixture plays the iPhone scanning,
    /// revealing its code, the person typing it on the Mac and confirming on
    /// both, and the iPhone answering the delivery check. One iPhone is then listed.
    func pairSyntheticIPhone(page: XCUIElement) {
        click("settings-pair-device")
        XCTAssertTrue(app.descendants(matching: .any)["devices-pairing-qr"].waitForExistence(timeout: 8))
        XCTAssertNoThrow(try deviceFixture("phone-scan"))
        XCTAssertTrue(app.descendants(matching: .any)["devices-pairing-waiting"].waitForExistence(timeout: 8))
        XCTAssertNoThrow(try deviceFixture("phone-reveal"))
        XCTAssertTrue(app.textFields["devices-pairing-code"].waitForExistence(timeout: 8))
        XCTAssertNoThrow(try deviceFixture("phone-complete"))
        click("devices-pairing-done")
        XCTAssertNoThrow(try deviceFixture("phone-poll"))
        let rename = app.buttons["devices-rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        for _ in 0..<6 where !rename.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
    }

    /// The runner's real click on a Devices button, scrolled into view first.
    func clickInPage(_ identifier: String, page: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing control: \(identifier)", file: file, line: line)
        for _ in 0..<6 where !button.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(button.isHittable, "Control is not visible: \(identifier)", file: file, line: line)
        button.click()
    }
}
