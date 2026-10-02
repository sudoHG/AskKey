import AppKit
import SwiftUI
import XCTest
@testable import AskKeyApp

/// Audit-only tests in an isolated source snapshot. No authentication is invoked.
final class AuditApplicationContractTests: XCTestCase {
    func testAllLiveAuthenticationReasonsAreAcceptedBySubprocess() {
        let productionReasons = [
            "Approve this Agent credential request",
            "Approve this Agent credential change",
            "Permanently delete recycled credential",
            "Replace credential with imported values",
            "Disable system authentication for read approvals",
        ]
        for reason in productionReasons {
            XCTAssertTrue(
                ManagementAuthenticationSubprocess.accepts(reasonKey: reason, argumentCount: 0),
                "Live product action cannot authenticate: \(reason)"
            )
        }
    }

    @MainActor
    func testManagementWindowProvidesAWorkingNativeCloseControl() {
        _ = NSApplication.shared
        let window = ManagementWindowConfiguration.makeWindow(rootView: EmptyView())
        defer { window.close() }
        XCTAssertTrue(window.styleMask.contains(.closable), "Management window must be closable")
        let close = window.standardWindowButton(.closeButton)
        XCTAssertNotNil(close, "The decorative circles have no actions; a functional close control is required")
        XCTAssertEqual(close?.isHidden, false)
        XCTAssertEqual(close?.isEnabled, true)
    }
}
