import Foundation
import AppKit
import XCTest

final class CredentialE2ETests: E2EBaseCase {
    private let createdCredentialName = "E2E Credential"
    private let editedCredentialName = "E2E Edited Credential"

    func testCredentialCreateEditRecycleRestorePersistsAfterRestart() throws {
        app.launch()

        XCTAssertTrue(app.buttons["unlock-management"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["credential-new"].exists)
        click("unlock-management")
        XCTAssertTrue(app.buttons["credential-new"].waitForExistence(timeout: 8))

        click("credential-new")
        clickVisibleButton(containing: "自定义凭证")
        replaceText(createdCredentialName, in: "credential-editor-name")
        replaceText("TOKEN", in: "credential-editor-component-name-0")
        replaceText("secret-value", in: "credential-editor-component-value-0")
        click("credential-editor-save")

        let createdRow = waitForCredential(named: createdCredentialName)
        let credentialID = credentialID(from: createdRow)
        createdRow.click()
        click("credential-edit-\(credentialID)")
        replaceText(editedCredentialName, in: "credential-editor-name")
        click("credential-editor-save")

        click("sidebar-all")
        let editedRow = waitForCredential(named: editedCredentialName)
        XCTAssertFalse(credentialRow(named: createdCredentialName).exists)

        editedRow.click()
        click("credential-delete-\(credentialID)")
        click("credential-delete-confirm-\(credentialID)")

        click("sidebar-recycle")
        XCTAssertTrue(app.staticTexts[editedCredentialName].waitForExistence(timeout: 8))
        click("credential-restore-\(credentialID)")
        click("sidebar-all")
        XCTAssertTrue(waitForCredential(named: editedCredentialName).exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["unlock-management"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["credential-\(credentialID)"].exists)
        click("unlock-management")
        XCTAssertTrue(waitForCredential(named: editedCredentialName).exists)
    }

    func testManagementStartsLockedAndRequiresExplicitUnlock() throws {
        app.launch()

        let lockedTitle = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "凭证管理已锁定", "凭证管理已锁定"))
            .firstMatch
        XCTAssertTrue(lockedTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["unlock-management"].isHittable)
        XCTAssertFalse(app.buttons["credential-new"].exists)

        click("unlock-management")
        XCTAssertTrue(app.buttons["credential-new"].waitForExistence(timeout: 8))
    }

    func testClosingManagementWindowRequiresUnlockWhenReopened() throws {
        app.launch()
        click("unlock-management")
        XCTAssertTrue(app.buttons["credential-new"].waitForExistence(timeout: 8))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.buttons["credential-new"].waitForNonExistence(timeout: 8))
        XCTAssertNotEqual(app.state, .notRunning, "Closing management must keep the menu bar app running")

        openManagementFromMenuBar()
        let lockedTitle = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "凭证管理已锁定", "凭证管理已锁定"))
            .firstMatch
        XCTAssertTrue(lockedTitle.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["unlock-management"].isHittable)
        XCTAssertFalse(app.buttons["credential-new"].exists)

        click("unlock-management")
        XCTAssertTrue(app.buttons["credential-new"].waitForExistence(timeout: 8))
    }

    private func openManagementFromMenuBar(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // The MenuBarExtra title follows the host language during scene creation
        // ("DEV" or "开发版"), before the isolated fixture sets its language.
        // Query only this application's single status item, not localized copy.
        let statusItems = app.statusItems
        let statusItem = statusItems.firstMatch
        let exists = statusItem.waitForExistence(timeout: 8)
        // Capture the full app and query before asserting. Do not resolve a
        // missing element merely to collect its debug description.
        let tree = XCTAttachment(string: app.debugDescription + "\nStatus item query:\n" + statusItems.debugDescription)
        tree.name = "Closed management — menu bar AX"
        tree.lifetime = .keepAlways
        add(tree)
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "Closed management — before menu click"
        screen.lifetime = .keepAlways
        add(screen)
        XCTAssertTrue(exists, "Missing Ask Key status item", file: file, line: line)
        XCTAssertEqual(statusItems.count, 1, "Ask Key must expose exactly one status item", file: file, line: line)
        let frameReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = statusItem.frame
            return frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
                && frame.width > 0 && frame.height > 0
        }, object: nil)
        let result = XCTWaiter.wait(for: [frameReady], timeout: 8)
        XCTAssertEqual(result, .completed, "Status item has no usable AX frame", file: file, line: line)

        // isHittable describes automatic hit-point calculation. Use the actual
        // AX element's center for the mouse event and require the real menu to
        // open; a missing or unresponsive menu still fails this test.
        statusItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        click("menubar-open-management", file: file, line: line)
    }

    private func clickVisibleButton(
        containing label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let button = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
            .firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing button containing: \(label)", file: file, line: line)
        XCTAssertTrue(button.isHittable, "Button is not visible: \(label)", file: file, line: line)
        button.click()
    }

    private func replaceText(
        _ value: String,
        in identifier: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let field = app.textFields[identifier].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Missing text field: \(identifier)", file: file, line: line)
        XCTAssertTrue(field.isHittable, "Text field is not visible: \(identifier)", file: file, line: line)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        // Synthetic typing can leave marked text in the user's active IME.
        // Paste the exact fixture and restore all previous clipboard formats.
        let clipboard = NSPasteboard.general
        let previousItems = (clipboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        clipboard.clearContents()
        clipboard.setString(value, forType: .string)
        defer {
            clipboard.clearContents()
            clipboard.writeObjects(previousItems)
        }
        field.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, value, file: file, line: line)
    }

    private func credentialRow(named name: String) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'credential-' AND label CONTAINS[c] %@", name))
            .firstMatch
    }

    private func waitForCredential(
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let row = credentialRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Missing credential row: \(name)", file: file, line: line)
        XCTAssertTrue(row.isHittable, "Credential row is not visible: \(name)", file: file, line: line)
        return row
    }

    private func credentialID(
        from row: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        let prefix = "credential-"
        XCTAssertTrue(row.identifier.hasPrefix(prefix), "Unexpected credential row identifier: \(row.identifier)", file: file, line: line)
        return String(row.identifier.dropFirst(prefix.count))
    }
}
