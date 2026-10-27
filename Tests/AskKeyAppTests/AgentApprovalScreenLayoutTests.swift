import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Hidden panels use the same factory, hosting and observers as live presentation.
@MainActor
final class AgentApprovalScreenLayoutTests: AskKeyAppTestCase {
    func testShortScreensKeepActionsVisibleWithVeryLongContentInBothLanguages() throws {
        _ = NSApplication.shared
        try ApprovalCardFixtures.withLanguages { language in
            for height: CGFloat in [300, 420, 520] {
                for expanded in [false, true] {
                    let request = ApprovalCardFixtures.request(.read,
                        name: String(repeating: "Synthetic Service ", count: 100),
                        purpose: String(repeating: "Synthetic instructions. ", count: 200),
                        display: ApprovalCardFixtures.display(environment: (1...100).map { "SYNTHETIC_TOKEN_\($0)" }))
                    let prompt = FrozenAgentApprovalPrompt(request: request,
                        expiresAt: Date().addingTimeInterval(300), timedAllowanceEnabled: true,
                        authenticationOutcome: .cancelled, detailsExpanded: expanded,
                        finish: { _ in XCTFail("Layout never decides a request") })
                    let visible = NSRect(x: -1200, y: 100, width: 1000, height: height)
                    let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in visible })
                    defer { panel.contentViewController = nil; panel.close() }
                    layout(panel)
                    XCTAssertFalse(panel.isVisible)
                    XCTAssertLessThanOrEqual(panel.frame.height, height + 0.5, "\(language), expanded: \(expanded)")
                    XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame))
                    let content = try XCTUnwrap(panel.contentView)
                    // Frame clamping alone could hide buttons. The complete intrinsic
                    // card, including all fixed actions and the footer, must also fit.
                    XCTAssertEqual(content.bounds.height, content.fittingSize.height, accuracy: 0.5)
                    XCTAssertLessThanOrEqual(content.fittingSize.height, height + 0.5)
                    XCTAssertGreaterThan(content.fittingSize.height, 200)
                }
            }
        }
    }

    func testDetailsExpansionScreenMoveAndReconfigurationRebudgetTheRealPanel() throws {
        _ = NSApplication.shared
        var visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = AppDelegate.makeFrozenApprovalPanel(ApprovalCardFixtures.prompt(.readDefault),
                                                       visibleFrame: { _ in visible })
        defer { panel.contentViewController = nil; panel.close() }
        layout(panel)
        let collapsedHeight = panel.frame.height
        let hosting = try XCTUnwrap(panel.contentViewController as? NSHostingController<AgentApprovalPanelContent>)
        hosting.rootView.prompt.detailsExpanded = true
        layout(panel)
        XCTAssertGreaterThan(panel.frame.height, collapsedHeight)
        visible = NSRect(x: -1200, y: 80, width: 1000, height: 350)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: panel)
        layout(panel)
        XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame))
        XCTAssertLessThan(hosting.rootView.layout.maximumHeight, 350, "native chrome is included in the budget")
        visible.size.height = 280
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        layout(panel)
        XCTAssertTrue(visible.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame))
        visible.size.height = 900
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        layout(panel)
        XCTAssertGreaterThan(panel.frame.height, 350, "moving back restores the natural expanded height")
        XCTAssertFalse(panel.isVisible)
    }

    private func layout(_ panel: NSPanel) {
        for _ in 0..<8 {
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
