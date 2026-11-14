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

    /// With exactly one paired iPhone, the runner turns **Approve agent
    /// requests** on: the sheet first says what leaves the Mac, then shows
    /// the code after (simulated) system authentication, the code is in no
    /// accessibility label or value, and the iPhone typing it turns approval
    /// on (#313).
    func testApproveAgentRequestsTurnsOnWithTheCodeTypedOnTheIPhone() throws {
        let page = openDevicesSettings(language: "en")
        pairSyntheticIPhone(page: page)
        clickApproverToggle(page: page)
        XCTAssertTrue(app.windows["settings"].sheets.firstMatch.waitForExistence(timeout: 8), "the switch opened no sheet")
        click("devices-approver-continue")
        XCTAssertTrue(app.descendants(matching: .any)["devices-approver-waiting"].waitForExistence(timeout: 8), "no code")
        try writeAccessibilityTreeForApproverCheck()
        try deviceFixture("approver-check-hidden")
        try deviceFixture("approver-confirm")
        click("devices-approver-done")
        waitUntilShown("devices-approver-caption", "Agent requests can also be decided on this iPhone.")
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

    /// The real click on the one paired iPhone's **Approve agent requests** switch.
    func clickApproverToggle(page: XCUIElement) {
        let toggle = app.descendants(matching: .any)["devices-approver-toggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 8), "Missing control: devices-approver-toggle")
        for _ in 0..<6 where !toggle.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(toggle.isHittable, "Control is not visible: devices-approver-toggle")
        toggle.click()
    }

    /// Writes the approver sheet's accessibility tree, with every identifier,
    /// label and value, for the App-side check that the code is not in it.
    /// The code shows only in this sheet; a snapshot of the whole Settings
    /// window can hang in CI once a text field had focus (#288).
    func writeAccessibilityTreeForApproverCheck() throws {
        let sheet = app.windows["settings"].sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 8))
        try Data(sheet.debugDescription.utf8).write(
            to: runDirectory.appendingPathComponent("approver-accessibility-tree.txt"), options: .atomic)
    }
}
