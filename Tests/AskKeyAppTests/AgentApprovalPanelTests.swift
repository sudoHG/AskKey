import AppKit
import XCTest
@testable import AskKeyAppKit

final class AgentApprovalPanelTests: AskKeyAppTestCase {
    @MainActor
    func testApprovalPanelUsesForegroundModalBehavior() {
        _ = NSApplication.shared

        let panel = AgentApprovalPanelFactory.make(
            contentSize: NSSize(width: 360, height: 430)
        )

        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertEqual(panel.level, .modalPanel)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.canBecomeKey)
    }

    /// Expanded Details make the card taller from its top; the panel moves up
    /// just enough to keep the buttons on screen. Never shown on screen here.
    @MainActor
    func testTallerPanelMovesUpIntoTheVisibleFrame() throws {
        _ = NSApplication.shared
        let panel = AgentApprovalPanelFactory.make(contentSize: NSSize(width: 300, height: 300))
        guard let screen = NSScreen.main else { throw XCTSkip("No screen") }
        let visible = screen.visibleFrame
        let fitting = NSRect(x: visible.midX - 150, y: visible.midY - 150, width: 300, height: 300)
        panel.setFrame(fitting, display: false)
        let placed = panel.frame
        AppDelegate.keepInsideVisibleFrame(panel)
        XCTAssertEqual(panel.frame, placed, "a panel that fits stays where it is")

        let height = min(640, visible.height)
        panel.setFrame(NSRect(x: placed.minX, y: visible.minY - 200, width: 300, height: height), display: false)
        AppDelegate.keepInsideVisibleFrame(panel)
        XCTAssertEqual(panel.frame.minY, visible.minY, accuracy: 0.5, "moved up just enough")
        XCTAssertLessThanOrEqual(panel.frame.maxY, visible.maxY + 0.5)
        XCTAssertEqual(panel.frame.minX, placed.minX)

        panel.setFrame(NSRect(x: placed.minX, y: visible.minY - 200, width: 300, height: visible.height + 100), display: false)
        AppDelegate.keepInsideVisibleFrame(panel)
        XCTAssertEqual(panel.frame.maxY, visible.maxY, accuracy: 0.5, "a panel taller than the screen keeps its top visible")
    }
}
