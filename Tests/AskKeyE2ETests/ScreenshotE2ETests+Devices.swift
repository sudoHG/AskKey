import XCTest

/// Settings → Devices screenshots (#288): 30–34 in English and 35–39 in Chinese.
extension ScreenshotE2ETests {
    func testDevicesScreensInEnglish() throws {
        try captureDevicesScreens(language: "en", tag: "en", firstNumber: 30)
    }

    func testDevicesScreensInChinese() throws {
        try captureDevicesScreens(language: "zh-Hans", tag: "zh", firstNumber: 35)
    }

    /// The list with one paired iPhone, the pairing sheet's QR code, waiting and code entry steps,
    /// and iCloud signed out, on the E2E App's fake device services. The fixture plays the iPhone,
    /// including the person typing its code, which never leaves the App.
    private func captureDevicesScreens(language: String, tag: String, firstNumber: Int) throws {
        func name(_ offset: Int, _ label: String) -> String { String(format: "%02d-%@-%@", firstNumber + offset, tag, label) }
        func fixture(_ command: String) throws {
            try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("device-\(command).json"))
            try sendFixtureCommand(command)
            let report = try waitForEvidence("device-\(command).json")
            XCTAssertEqual(report["ok"] as? Bool, true, "\(command): \(report)")
        }
        var notes: [String] = []
        var walks = 0
        func walkAccessibility() throws {
            try fixture("ax-walk")
            walks += 1
            attachDeviceFile("device-ax-walk-\(walks).txt")
        }
        func timed(_ label: String, _ query: () -> Bool) {
            let began = Date()
            let found = query()
            notes.append("\(label): found=\(found) in \(String(format: "%.1f", Date().timeIntervalSince(began))) s")
        }
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "screenshots-devices"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = language
        app.launch()
        addTeardownBlock { [app] in app?.terminate() } // a hung query must not also hang the teardown
        moveManagementAboveDock()
        click("unlock-management")
        click("sidebar-settings")
        let pair = app.buttons["settings-pair-device"].firstMatch
        let page = app.windows["settings"].scrollViews.containing(.button, identifier: "settings-pair-device").firstMatch
        let sheet = app.windows["settings"].sheets.firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 8))
        for _ in 0..<6 where !pair.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        try walkAccessibility()
        // #298 diagnostics: ways of clicking Pair a Device…, while the fixture records the mouse
        // events the App receives; the fixture starts the session if none opened the sheet.
        let clicks: [(String, () -> Void)] = [
            ("click", { pair.click() }),
            ("coordinate click", { pair.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click() }),
            ("hover, then press", { pair.hover(); pair.press(forDuration: 0.2) }),
            ("click near the leading edge", { pair.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).click() })
        ]
        for (label, perform) in clicks where !sheet.exists {
            try fixture("snapshot")
            notes.append("\(label): enabled=\(pair.isEnabled) hittable=\(pair.isHittable) frame=\(pair.frame)")
            perform()
            notes.append(sheet.waitForExistence(timeout: 3) ? "sheet" : "no sheet")
        }
        if !sheet.exists { notes.append("fixture start"); try fixture("start-pairing") }
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), "No pairing sheet")
        attachDeviceDiagnostics(notes)
        XCTAssertTrue(app.descendants(matching: .any)["devices-pairing-qr"].waitForExistence(timeout: 8))
        captureSheet(name(1, "devices-pairing-qr-code"))
        try fixture("phone-scan")
        XCTAssertTrue(app.descendants(matching: .any)["devices-pairing-waiting"].waitForExistence(timeout: 8))
        captureSheet(name(2, "devices-pairing-waiting"))
        try fixture("phone-reveal")
        XCTAssertTrue(app.textFields["devices-pairing-code"].waitForExistence(timeout: 8))
        captureSheet(name(3, "devices-pairing-code-entry"))
        // #298 diagnostics: the English run drops the code field's focus before the field goes
        // away; the Chinese run keeps it until after the sheet has closed.
        if language == "en" { try fixture("resign-focus") }
        try fixture("phone-complete")
        click("devices-pairing-done")
        try fixture("phone-poll")
        try walkAccessibility()
        let lastReached = language == "en" ? "Last reached" : "\u{4E0A}\u{6B21}\u{8054}\u{7CFB}"
        let reached = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", lastReached, lastReached)
        timed("text query after Done") { app.descendants(matching: .any).matching(reached).firstMatch.waitForExistence(timeout: 2) }
        if language != "en" {
            try fixture("resign-focus")
            try walkAccessibility()
            timed("text query after dropping focus") { app.descendants(matching: .any).matching(reached).firstMatch.waitForExistence(timeout: 2) }
        }
        attachDeviceDiagnostics(notes)
        let row = app.buttons["devices-rename"].firstMatch
        for _ in 0..<6 where !row.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        waitForText(lastReached, containing: true)
        capture(name(0, "devices-list"))
        try fixture("account-signed-out")
        waitForText(language == "en" ? "iCloud is signed out" : "iCloud \u{5DF2}\u{9000}\u{51FA}\u{767B}\u{5F55}", containing: true)
        capture(name(4, "devices-icloud-signed-out"))
        XCTAssertEqual(notes.first { $0.hasSuffix("sheet") || $0 == "fixture start" }, "sheet", "Pair a Device…: \(notes)")
    }

    /// The fixture's record (the coordinator's states, the App's mouse events and accessibility
    /// walks) and the notes so far, attached at once so they survive a later query timeout.
    private func attachDeviceDiagnostics(_ notes: [String]) {
        let record = (try? String(contentsOf: runDirectory.appendingPathComponent("device-transitions.json"), encoding: .utf8)) ?? "none"
        let attachment = XCTAttachment(string: notes.joined(separator: "\n") + "\n\n" + record)
        attachment.name = "device-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachDeviceFile(_ file: String) {
        let text = (try? String(contentsOf: runDirectory.appendingPathComponent(file), encoding: .utf8)) ?? "missing \(file)"
        let attachment = XCTAttachment(string: text)
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
