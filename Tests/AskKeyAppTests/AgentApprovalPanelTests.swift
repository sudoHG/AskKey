import AppKit
import XCTest
@testable import AskKeyApp

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
    }
}
