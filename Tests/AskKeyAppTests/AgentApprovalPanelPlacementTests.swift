import AppKit
import XCTest
@testable import AskKeyAppKit

final class AgentApprovalPanelPlacementTests: XCTestCase {
    private let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
    private let other = NSRect(x: -1920, y: 0, width: 1920, height: 1080)

    func testPointerDisplayWinsOverKeyWindowAndMainDisplay() {
        XCTAssertEqual(AgentApprovalPanelPlacement.screenFrame(
            pointer: NSPoint(x: -100, y: 500), screens: [main, other], keyWindowScreen: main, mainScreen: main
        ), other)
    }

    func testScreenSelectionFallsBackToKeyWindowThenMain() {
        let pointer = NSPoint(x: 10_000, y: 10_000)
        XCTAssertEqual(AgentApprovalPanelPlacement.screenFrame(
            pointer: pointer, screens: [main, other], keyWindowScreen: other, mainScreen: main
        ), other)
        XCTAssertEqual(AgentApprovalPanelPlacement.screenFrame(
            pointer: pointer, screens: [main, other], keyWindowScreen: nil, mainScreen: main
        ), main)
        XCTAssertNil(AgentApprovalPanelPlacement.screenFrame(
            pointer: pointer, screens: [], keyWindowScreen: nil, mainScreen: nil
        ))
    }

    func testPanelCentersOnSelectedDisplayAndKeepsTallPanelTopVisible() {
        XCTAssertEqual(AgentApprovalPanelPlacement.centeredOrigin(size: NSSize(width: 400, height: 500), visibleFrame: other),
            NSPoint(x: -1160, y: 290))
        let tall = AgentApprovalPanelPlacement.centeredOrigin(size: NSSize(width: 400, height: 1200), visibleFrame: other)
        XCTAssertEqual(tall.y + 1200, other.maxY)
    }
}
