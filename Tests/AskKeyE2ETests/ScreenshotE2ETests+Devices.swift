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
        func fixture(_ command: String, _ argument: String = "requested") throws {
            try? FileManager.default.removeItem(at: runDirectory.appendingPathComponent("device-\(command).json"))
            try "\(argument)\n".write(to: runDirectory.appendingPathComponent("command-\(command).txt"), atomically: true, encoding: .utf8)
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
        // #298 diagnostics: whether another button in the same page opens its sheet in this
        // scenario, then XCTest's clicks on Pair a Device… and a click the App posts to itself,
        // while the fixture records the mouse events the App receives. The fixture starts the
        // session if none of them opened the sheet.
        let export = app.buttons["settings-export-backup"].firstMatch
        notes.append("export: hittable=\(export.isHittable) frame=\(export.frame)")
        export.click()
        if sheet.waitForExistence(timeout: 5) {
            notes.append("export sheet")
            click("backup-export-cancel")
            notes.append("export sheet closed=\(sheet.waitForNonExistence(timeout: 5))")
        } else {
            notes.append("export: no sheet, alerts=\(app.alerts.count)")
            if app.alerts.firstMatch.exists { app.alerts.firstMatch.buttons.firstMatch.click() }
        }
        let clicks: [(String, () -> Void)] = [
            ("click", { pair.click() }),
            ("hover, then press", { pair.hover(); pair.press(forDuration: 0.2) })
        ]
        var clickOpened: [Bool] = []
        for (label, perform) in clicks where !sheet.exists {
            try fixture("snapshot")
            notes.append("\(label): enabled=\(pair.isEnabled) hittable=\(pair.isHittable) frame=\(pair.frame)")
            perform()
            clickOpened.append(sheet.waitForExistence(timeout: 3))
            notes.append(clickOpened.last == true ? "sheet" : "no sheet")
        }
        let centre = "\(pair.frame.midX) \(pair.frame.midY)"
        for command in ["inject-click"] where !sheet.exists {
            try fixture(command, centre)
            notes.append("\(command) at \(centre): " + (sheet.waitForExistence(timeout: 3) ? "sheet" : "no sheet"))
        }
        try fixture("write-log")
        attachDeviceFile("device-log.txt")
        attachDeviceFile("device-stderr.txt")
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
        try fixture("phone-complete")
        click("devices-pairing-done")
        try fixture("phone-poll")
        try walkAccessibility()
        // #298 diagnostics: the same text query in the Settings window, then in the whole App.
        let lastReached = language == "en" ? "Last reached" : "\u{4E0A}\u{6B21}\u{8054}\u{7CFB}"
        let settings = app.windows["settings"].firstMatch
        func textQuery(_ text: String, in root: XCUIElement) -> XCUIElement {
            root.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }
        let rename = app.buttons["devices-rename"].firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        try fixture("write-log")
        attachDeviceFile("device-log.txt")
        attachDeviceFile("device-stderr.txt")
        attachDeviceDiagnostics(notes)
        let sidebar = app.buttons["sidebar-settings"].firstMatch
        timed("sidebar text query after Done") { textQuery("Settings", in: sidebar).waitForExistence(timeout: 2) }
        attachDeviceDiagnostics(notes)
        timed("Settings window text query after Done") { textQuery(lastReached, in: settings).waitForExistence(timeout: 8) }
        attachDeviceDiagnostics(notes)
        let row = app.buttons["devices-rename"].firstMatch
        for _ in 0..<6 where !row.isHittable { page.scroll(byDeltaX: 0, deltaY: -300) }
        XCTAssertTrue(textQuery(lastReached, in: settings).waitForExistence(timeout: 8))
        captureSettingsWindow(name(0, "devices-list"))
        try fixture("account-signed-out")
        let signedOut = language == "en" ? "iCloud is signed out" : "iCloud \u{5DF2}\u{9000}\u{51FA}\u{767B}\u{5F55}"
        XCTAssertTrue(textQuery(signedOut, in: settings).waitForExistence(timeout: 8))
        captureSettingsWindow(name(4, "devices-icloud-signed-out"))
        // Last, as it may time out: the same text query over the whole App.
        timed("App text query after pairing") { textQuery(signedOut, in: app).waitForExistence(timeout: 2) }
        attachDeviceDiagnostics(notes)
        XCTAssertEqual(clickOpened.first, true, "Pair a Device…: \(notes)")
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

    /// The Settings window alone: the App-wide window list can include system text-input windows.
    private func captureSettingsWindow(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows["settings"].firstMatch.screenshot())
        attachment.name = name + ".png"
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
