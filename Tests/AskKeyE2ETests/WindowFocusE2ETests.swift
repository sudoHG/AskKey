import XCTest

final class WindowFocusE2ETests: E2EBaseCase {
    /// The About panel has no parent window. Becoming key over the foreground
    /// management window must not switch Ask Key to an accessory app, which
    /// would deactivate it and leave the panel behind other apps.
    func testAboutPanelFromAppMenuKeepsAskKeyInFront() throws {
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        XCTAssertTrue(app.buttons["unlock-management"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8), "Management must start in front")

        // Anything other than the management window is the panel this flow opens.
        let windowTypes = [XCUIElement.ElementType.window, .dialog].map { NSNumber(value: $0.rawValue) }
        let otherWindows = app.children(matching: .any).matching(NSPredicate(
            format: "elementType IN %@ AND identifier != %@", windowTypes, "settings"
        ))
        XCTAssertEqual(otherWindows.count, 0, app.debugDescription)

        openAboutFromAppMenu()
        let about = otherWindows.firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 8), "About panel did not open\n" + app.debugDescription)
        // The Dock policy follows key-window changes asynchronously.
        assertStaysInForeground(seconds: 3, "Opening About must keep Ask Key active")
        XCTAssertTrue(about.isHittable, "The About panel must be in front")
        XCTAssertTrue(app.windows["settings"].exists, "Management stays open behind the panel")

        let close = about.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(close.waitForExistence(timeout: 8), about.debugDescription)
        close.click()
        XCTAssertTrue(about.waitForNonExistence(timeout: 8))
        assertStaysInForeground(seconds: 2, "Closing About must return to management")
        XCTAssertTrue(app.buttons["unlock-management"].isHittable)
    }

    private func openAboutFromAppMenu(file: StaticString = #filePath, line: UInt = #line) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 8), app.debugDescription, file: file, line: line)
        // The app menu carries the bundle name; the companion language setting
        // may localize it, so accept both product names.
        let appMenu = menuBar.menuBarItems
            .matching(NSPredicate(format: "title IN %@", ["Ask Key", "请旨"]))
            .firstMatch
        XCTAssertTrue(appMenu.waitForExistence(timeout: 8), menuBar.debugDescription, file: file, line: line)
        appMenu.click()
        let aboutPrefixes = ["About", "关于"] // i18n-literal: English or Chinese About menu item title
        let about = appMenu.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH %@ OR title BEGINSWITH %@", aboutPrefixes[0], aboutPrefixes[1]))
            .firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 8), appMenu.debugDescription, file: file, line: line)
        about.click()
    }

    private func assertStaysInForeground(
        seconds: TimeInterval,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            guard app.state == .runningForeground else {
                XCTFail("\(message); state: \(app.state.rawValue)", file: file, line: line)
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
    }
}
