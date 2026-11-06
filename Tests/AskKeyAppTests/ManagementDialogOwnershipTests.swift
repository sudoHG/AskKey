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

    func testParentlessAppWindowsJoinTheManagementSession() {
        withWindows { management, sparkleWindow, _, _ in
            // The standard About panel is a titled NSPanel that cannot become main;
            // Sparkle's status window and update alert are titled windows that can.
            let about = Self.makeAboutLikePanel()
            defer { about.close() }
            XCTAssertTrue(hasDialog(management, key: about, main: management))
            XCTAssertTrue(hasDialog(management, key: about, main: nil))

            sparkleWindow.styleMask = [.titled, .closable, .resizable]
            XCTAssertTrue(hasDialog(management, key: sparkleWindow, main: sparkleWindow))
            sparkleWindow.level = .floating
            XCTAssertTrue(hasDialog(management, key: sparkleWindow, main: sparkleWindow))
        }
    }

    func testApprovalPanelsForeignSheetsAndModalLevelWindowsDoNotJoinTheManagementSession() {
        withWindows { management, sheet, child, modal in
            let approval = AgentApprovalPanelFactory.make(contentSize: NSSize(width: 360, height: 430))
            defer { approval.close() }
            XCTAssertFalse(hasDialog(management, key: approval, main: management))

            sheet.styleMask = [.titled]
            sheet.fixtureSheetParent = approval
            XCTAssertFalse(hasDialog(management, key: sheet, main: management))
            child.styleMask = [.titled]
            child.parent = approval
            XCTAssertFalse(hasDialog(management, key: child, main: management))

            // An app-modal alert still counts only while management is main.
            modal.styleMask = [.titled]
            modal.level = .modalPanel
            modal.fixtureVisible = true
            XCTAssertFalse(hasDialog(management, key: modal, main: nil, modal: modal))
            XCTAssertTrue(hasDialog(management, key: modal, main: management, modal: modal))
        }
    }

    func testAboutPanelOverForegroundManagementKeepsTheDockAndClosingReturnsToManagement() {
        withWindows { management, _, _, _ in
            let about = Self.makeAboutLikePanel()
            defer { about.close() }
            var policy = ManagementDockPolicy()
            XCTAssertEqual(policy.handle(.managementWindowOpenedByUser), .regular)

            XCTAssertNil(policy.handle(windowState(management, key: about)))
            XCTAssertTrue(policy.isManagementWindowForeground)
            XCTAssertEqual(policy.activationPolicy, .regular)

            // Closing the panel makes management key again without a transition.
            XCTAssertNil(policy.handle(windowState(management, key: management)))
            XCTAssertEqual(policy.activationPolicy, .regular)

            // Management closed or miniaturized still means accessory, panel or not.
            XCTAssertEqual(policy.handle(windowState(management, key: about, visible: false)), .accessory)
            XCTAssertEqual(policy.handle(windowState(management, key: about)), .regular)
            XCTAssertEqual(policy.handle(windowState(management, key: about, miniaturized: true)), .accessory)
        }
    }

    func testApprovalPanelOverForegroundManagementStillLeavesTheDock() {
        withWindows { management, _, _, _ in
            let approval = AgentApprovalPanelFactory.make(contentSize: NSSize(width: 360, height: 430))
            defer { approval.close() }
            var policy = ManagementDockPolicy()
            XCTAssertEqual(policy.handle(.managementWindowOpenedByUser), .regular)
            XCTAssertEqual(policy.handle(windowState(management, key: approval)), .accessory)
        }
    }

    /// The same snapshot `syncManagementWindowDockState` sends, with management
    /// active and visible unless stated otherwise.
    private func windowState(
        _ management: NSWindow, key: NSWindow, visible: Bool = true, miniaturized: Bool = false
    ) -> ManagementDockPolicy.Event {
        .managementWindowState(
            visible: visible,
            miniaturized: miniaturized,
            key: key === management,
            applicationActive: true,
            ownedDialog: hasDialog(management, key: key, main: management)
        )
    }

    private static func makeAboutLikePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        return panel
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
