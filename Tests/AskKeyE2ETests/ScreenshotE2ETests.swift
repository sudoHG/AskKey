import AppKit
import XCTest

/// Optional visual evidence, run separately from the required desktop gate.
final class ScreenshotE2ETests: E2EBaseCase {
    func testWelcomeAndManagementScreens() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "screenshots-welcome"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        moveManagementAboveDock()
        waitForText("Create First Credential")
        capture("01-welcome-first-launch")
        clickLabel("Create First Credential")
        waitForText("What do you want to save?")
        capture("04-template-chooser")
        clickLabel("Custom Credential", containing: true)
        replaceText("CI Demo Credential", identifier: "credential-editor-name")
        replaceText("TOKEN", identifier: "credential-editor-component-name-0")
        replaceText("synthetic-ci-token", identifier: "credential-editor-component-value-0")
        capture("05-new-credential")
        click("credential-editor-save")
        waitForText("Start Using")
        capture("02-welcome-after-first-save")
        clickLabel("Start Using")
        click("unlock-management")
        click("sidebar-all")
        waitForText("CI Demo Credential", containing: true)
        capture("03-all-credentials")
        clickLabel("Import from File", containing: true)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        paste("CI_TOKEN=synthetic-import-token\nCI_REGION=test-region", into: editor)
        clickLabel("Parse and Preview")
        waitForText("Import Preview")
        capture("06-import-preview")
        click("sidebar-agent")
        XCTAssertTrue(app.buttons["onboarding-review-codex"].waitForExistence(timeout: 8))
        capture("07-agent-access")
        click("sidebar-settings")
        XCTAssertTrue(app.buttons["settings-read-auth-action"].waitForExistence(timeout: 8))
        capture("10-settings")
        app.terminate()
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "connected"
        app.launch()
        moveManagementAboveDock()
        XCTAssertTrue(app.buttons["unlock-management"].waitForExistence(timeout: 8))
        capture("11-locked")
    }

    func testPendingRequestsAndAccessRecords() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-deny"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        XCTAssertTrue(app.buttons["approval-deny"].waitForExistence(timeout: 8))
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        moveManagementAboveDock()
        click("unlock-management")
        click("sidebar-pending")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-'"))
            .firstMatch.waitForExistence(timeout: 8))
        capture("08-pending-requests")
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-'"))
            .firstMatch.click()
        click("approval-deny")
        _ = try waitForEvidence("approval-result.json")
        click("sidebar-records")
        waitForText("Access records")
        capture("09-access-records")
    }

    func testApprovalPromptScreens() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-screenshots-write"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        XCTAssertTrue(app.buttons["approval-reveal-frozen-material"].waitForExistence(timeout: 8))
        capture("12-approval-default", approval: true)
        click("approval-reveal-frozen-material")
        waitForText("synthetic-ci-approval", containing: true)
        capture("13-approval-details", approval: true)
        clickLabel("Hide")
        try sendFixtureCommand("cancel-authentication")
        _ = try waitForEvidence("authentication-cancellation-ready.json")
        click("approval-reveal-frozen-material")
        waitForText("Unable to view:", containing: true)
        capture("14-approval-cancelled-authentication", approval: true)
        click("approval-deny")
    }

    private func capture(_ name: String, approval: Bool = false) {
        // AppKit's floating approval NSPanel is exposed as a dialog, while the
        // management scene is a window. Query both before taking a window crop.
        let windows = app.windows.allElementsBoundByIndex + app.dialogs.allElementsBoundByIndex
        let window = approval
            ? windows.first { $0.buttons["approval-deny"].exists }
            : windows.first { !$0.buttons["approval-deny"].exists }
        guard let window else {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Missing screenshot window — UI tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("Missing window for \(name)")
            return
        }
        XCTAssertTrue(window.isHittable)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = name + ".png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func moveManagementAboveDock() {
        let window = app.windows["settings"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 8))
        let origin = window.frame.origin
        guard origin.y > 34 else { return }
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 14))
        titleBar.press(forDuration: 0.1, thenDragTo:
            titleBar.withOffset(CGVector(dx: 0, dy: 34 - origin.y)))
    }

    private func clickLabel(_ text: String, containing: Bool = false) {
        let predicate = NSPredicate(format: containing ? "label CONTAINS[c] %@" : "label == %@", text)
        let button = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button: \(text)")
        XCTAssertTrue(button.isHittable)
        button.click()
    }

    private func waitForText(_ text: String, containing: Bool = false) {
        let predicate = NSPredicate(format: containing
            ? "label CONTAINS %@ OR value CONTAINS %@" : "label == %@ OR value == %@", text, text)
        XCTAssertTrue(app.descendants(matching: .any).matching(predicate).firstMatch
            .waitForExistence(timeout: 8), "Missing content: \(text)")
    }

    private func replaceText(_ text: String, identifier: String) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        paste(text, into: field)
        XCTAssertEqual(field.value as? String, text)
    }

    private func paste(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.isHittable)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        let clipboard = NSPasteboard.general
        let previous = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        defer { clipboard.clearContents(); clipboard.writeObjects(previous) }
        field.typeKey("v", modifierFlags: .command)
    }
}
