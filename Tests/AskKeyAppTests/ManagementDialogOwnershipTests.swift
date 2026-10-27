import AppKit
import XCTest
@testable import AskKeyAppKit

@MainActor
final class ManagementDialogOwnershipTests: AskKeyAppTestCase {
    func testAttachedSheetCountsEvenDuringKeyWindowHandoff() {
        withWindows { management, sheet, _, _ in
            management.fixtureAttachedSheet = sheet
            sheet.fixtureVisible = true
            XCTAssertTrue(hasDialog(management, key: nil, main: management))
            sheet.fixtureVisible = false
            XCTAssertFalse(hasDialog(management, key: nil, main: management))
        }
    }

    func testNestedSheetsAndChildWindowsBelongToManagement() {
        withWindows { management, editor, picker, _ in
            editor.fixtureSheetParent = management
            picker.fixtureSheetParent = editor
            XCTAssertTrue(hasDialog(management, key: picker, main: management))
            picker.fixtureSheetParent = nil
            picker.parent = editor
            XCTAssertTrue(hasDialog(management, key: picker, main: management))
        }
    }

    func testUnparentedModalPickerOrAlertCountsForTheMainManagementSession() {
        withWindows { management, editor, modal, other in
            modal.fixtureVisible = true
            XCTAssertTrue(hasDialog(management, key: modal, main: management, modal: modal))
            editor.fixtureSheetParent = management
            XCTAssertTrue(hasDialog(management, key: modal, main: editor, modal: modal))
            XCTAssertFalse(hasDialog(management, key: modal, main: other, modal: modal))
            XCTAssertFalse(hasDialog(management, key: modal, main: nil, modal: modal))
            modal.fixtureVisible = false
            XCTAssertFalse(hasDialog(management, key: modal, main: management, modal: modal))
        }
    }

    func testStandaloneApprovalAndPopoverNeverCountAsManagementDialogs() {
        withWindows { management, approval, popover, other in
            for key in [approval, popover, other, management] {
                XCTAssertFalse(hasDialog(management, key: key, main: management))
            }
            approval.fixtureAttachedSheet = other
            other.fixtureSheetParent = approval
            XCTAssertFalse(hasDialog(management, key: other, main: approval))
        }
    }

    private func hasDialog(
        _ window: NSWindow, key: NSWindow?, main: NSWindow?, modal: NSWindow? = nil
    ) -> Bool {
        ManagementDockPolicy.hasManagementDialog(
            window: window, keyWindow: key, mainWindow: main, modalWindow: modal
        )
    }

    private func withWindows(_ body: (DialogWindow, DialogWindow, DialogWindow, DialogWindow) -> Void) {
        _ = NSApplication.shared
        let windows = (0..<4).map { _ in
            let window = DialogWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            return window
        }
        defer {
            for window in windows {
                window.fixtureVisible = false
                window.fixtureSheetParent = nil
                window.fixtureAttachedSheet = nil
                window.parent = nil
                window.close()
            }
        }
        body(windows[0], windows[1], windows[2], windows[3])
    }
}

/// Relationship snapshots only: never attach, order, or activate native dialogs.
@MainActor
private final class DialogWindow: NSWindow {
    var fixtureSheetParent: NSWindow?
    var fixtureAttachedSheet: NSWindow?
    var fixtureVisible = false
    private var fixtureParent: NSWindow?

    override var sheetParent: NSWindow? { fixtureSheetParent }
    override var attachedSheet: NSWindow? { fixtureAttachedSheet }
    override var isVisible: Bool { fixtureVisible }
    override var parent: NSWindow? {
        get { fixtureParent }
        set { fixtureParent = newValue }
    }
}
