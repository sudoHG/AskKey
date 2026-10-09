import AppKit
import XCTest

/// Optional visual evidence, run separately from the required desktop gate.
final class ScreenshotE2ETests: E2EBaseCase {
    func testWelcomeAndManagementScreens() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "screenshots-welcome"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        moveManagementAboveDock()
        XCTAssertTrue(app.buttons["welcome-create-credential"].waitForExistence(timeout: 8))
        capture("01-welcome-first-launch")
        click("welcome-create-credential")
        XCTAssertTrue(app.buttons["credential-template-custom"].waitForExistence(timeout: 8))
        capture("04-template-chooser")
        click("credential-template-custom")
        replaceText("CI Demo Credential", identifier: "credential-editor-name")
        replaceText("TOKEN", identifier: "credential-editor-component-name-0")
        replaceText("synthetic-ci-token", identifier: "credential-editor-component-value-0")
        capture("05-new-credential")
        click("credential-editor-save")
        XCTAssertTrue(app.buttons["welcome-later"].waitForExistence(timeout: 8))
        capture("02-welcome-after-first-save")
        click("welcome-later")
        click("unlock-management")
        click("sidebar-all")
        waitForText("CI Demo Credential", containing: true)
        capture("03-all-credentials")
        clickLabel("Import from File", containing: true)
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        paste("CI_TOKEN=synthetic-import-token\nCI_REGION=test-region", into: editor)
        clickLabel("Parse and Preview")
        XCTAssertTrue(app.textFields["credential-import-name"].waitForExistence(timeout: 8))
        capture("06-import-preview")
        click("sidebar-agent")
        XCTAssertTrue(app.buttons["onboarding-review-codex"].waitForExistence(timeout: 8))
        capture("07-agent-access")
        click("sidebar-settings")
        XCTAssertTrue(app.buttons["settings-agent-access"].waitForExistence(timeout: 8))
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'request-deny-'"))
            .firstMatch.waitForExistence(timeout: 8))
        capture("08-pending-requests")
        click("sidebar-records")
        waitForText("Records who asked for what and the outcome, never credential contents. Kept for 90 days.")
        capture("09-access-records")
    }

    func testApprovalPromptScreens() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-screenshots"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        XCTAssertTrue(app.buttons["approval-details"].waitForExistence(timeout: 8))
        waitForText("“Claude Code” wants to use “Staging API”")
        waitForText("to run ./deploy.sh", containing: true)
        XCTAssertEqual(app.buttons["approval-allow-once"].label, "Allow Once")
        XCTAssertEqual(app.buttons["approval-allow-timed"].label, "Allow for 30 Minutes")
        XCTAssertEqual(app.buttons["approval-deny"].label, "Deny")
        waitForText("Esc to decide later")
        XCTAssertFalse(app.staticTexts["Requested by"].exists, "everything else stays behind Details")
        capture("12-approval-default", approval: true)
        click("approval-details")
        waitForText("Requested by")
        waitForText("Claude Code (not verified)")
        waitForText("Hands over")
        waitForText("Staging API → environment variable STAGING_API_TOKEN")
        waitForText("For 30 minutes, any agent or command in your Mac account can read this credential", containing: true)
        capture("13-approval-details", approval: true)
        click("approval-details")
        try sendFixtureCommand("cancel-authentication")
        click("approval-allow-once")
        let cancelled = try waitForEvidence("authentication-cancelled.json")
        XCTAssertEqual(cancelled["outcome"] as? String, "cancelled")
        XCTAssertTrue(app.descendants(matching: .any)["approval-authentication-cancelled"].waitForExistence(timeout: 8))
        waitForText("Authentication cancelled. Nothing was handed over.")
        XCTAssertEqual(app.buttons["approval-allow-once"].label, "Allow Once", "the default stays the same")
        XCTAssertEqual(app.buttons["approval-allow-timed"].label, "Allow for 30 Minutes")
        try assertTargetExecutionCount(0)
        capture("14-approval-cancelled-authentication", approval: true)
        click("approval-deny")
        _ = try waitForEvidence("approval-result.json")
    }

    func testMetadataWriteApprovalScreen() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-metadata-screenshots"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        XCTAssertTrue(app.buttons["approval-deny"].waitForExistence(timeout: 8))
        waitForText("“E2E Agent” wants to create the credential “Staging API”")
        waitForText("In the new group “Staging Services”")
        XCTAssertEqual(app.buttons["approval-allow-once"].label, "Create")
        XCTAssertFalse(app.buttons["approval-reveal-frozen-material"].exists, "values stay behind Details")
        capture("15-approval-credential-metadata", approval: true)
        click("approval-details")
        waitForText("Contents")
        waitForText("token · given to programs as environment variable STAGING_TOKEN")
        XCTAssertTrue(app.buttons["approval-reveal-frozen-material"].waitForExistence(timeout: 8))
        waitForText("Instructions")
        waitForText("Use only for staging API requests.", containing: true)
        XCTAssertFalse(app.staticTexts["After you approve"].exists, "Details never repeat the subtitle")
        XCTAssertFalse(app.staticTexts["Before"].exists)
        XCTAssertFalse(app.staticTexts["After"].exists)
        XCTAssertFalse(app.staticTexts["Unchanged"].exists)
        click("approval-deny")
        let result = try waitForEvidence("approval-result.json")
        XCTAssertEqual(result["outcome"] as? String, "denied")
    }

    func testOrganizationApprovalScreen() throws {
        app.launchEnvironment["ASKKEY_E2E_SCENARIO"] = "approval-organization-screenshots"
        app.launchEnvironment["ASKKEY_E2E_LANGUAGE"] = "en"
        app.launch()
        _ = try waitForEvidence("approval-pending.json")
        XCTAssertTrue(app.buttons["approval-deny"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons["approval-allow-once"].label, "Apply")
        waitForText("“E2E Agent” wants to organize your groups")
        waitForText("6 steps, one of which merges groups, affecting 3 hidden credentials")
        XCTAssertFalse(app.buttons["approval-reveal-frozen-material"].exists)
        XCTAssertFalse(app.buttons["approval-allow-timed"].exists)
        capture("16-approval-organization", approval: true)
        click("approval-details")
        waitForText("Create the group “Staging Services”", containing: true)
        waitForText("Move the credential “Staging API” from “Old Services” to “Staging Services”", containing: true)
        waitForText("Rename the group “Old Services” to “Renamed Services”", containing: true)
        waitForText("When it's renamed, the group has 3 credentials (2 hidden from agents).", containing: true)
        waitForText("Its 3 credentials (2 hidden from agents) won't be deleted and will become “Ungrouped”.", containing: true)
        let operations = app.scrollViews["approval-organization-operations"]
        XCTAssertTrue(operations.exists)
        operations.scroll(byDeltaX: 0, deltaY: -600)
        waitForText("Create the group “Existing Private Services”", containing: true)
        waitForText("This group already exists, so nothing is created or changed. It has 1 credential (1 hidden from agents).",
                    containing: true)
        waitForText("E2E Agent asked to rename “Merge Source” to “Existing Merge Services”; “Existing Merge Services” already exists and is hidden from it, so the groups merge.",
                    containing: true)
        waitForText("“Merge Source” disappears and “Existing Merge Services” will have 4 credentials (3 hidden from agents). A merge can't be undone automatically.",
                    containing: true)
        XCTAssertTrue(app.buttons["approval-allow-once"].isHittable)
        XCTAssertTrue(app.buttons["approval-deny"].isHittable)
        capture("17-approval-organization-existing-targets", approval: true)
        click("approval-deny")
        let result = try waitForEvidence("approval-result.json")
        XCTAssertEqual(result["outcome"] as? String, "denied")
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
