import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Hidden panels use the same factory, hosting and observers as live presentation.
@MainActor
final class AgentApprovalScreenLayoutTests: AskKeyAppTestCase {
    private var visiblePanels: [NSPanel] = []

    override func tearDown() {
        for panel in visiblePanels {
            panel.orderOut(nil)
            panel.contentViewController = nil
            panel.close()
        }
        visiblePanels = []
        super.tearDown()
    }

    func testVisibleTitleSubtitleAndActionsStayInsideShortPanelsOnCI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true", environment["CI"] == "true" else {
            throw XCTSkip("Visible approval geometry runs only in the GitHub Actions test process")
        }
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main).visibleFrame
        try ApprovalCardFixtures.withLanguages { language in
            for height: CGFloat in [300, 420] {
                for expanded in [false, true] {
                    var prompt = ApprovalCardFixtures.prompt(.readDefault)
                    prompt.detailsExpanded = expanded
                    let visible = NSRect(x: screen.minX + 20, y: screen.minY + 20,
                                         width: screen.width - 40, height: height)
                    let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in visible })
                    visiblePanels.append(panel)
                    panel.makeKeyAndOrderFront(nil)
                    layout(panel)
                    XCTAssertTrue(panel.isVisible)
                    let nodes = accessibilityElements(try XCTUnwrap(panel.contentView))
                    var frames: [String: CGRect] = [:]
                    for identifier in ["approval-title", "approval-subtitle", "approval-allow-once",
                                       "approval-allow-timed", "approval-deny"] {
                        let node = try XCTUnwrap(nodes.first { $0.identifier == identifier },
                            "\(language), \(height), Details=\(expanded): missing \(identifier); nodes: \(nodes.map(\.description))")
                        let frame = try XCTUnwrap(node.frame, identifier)
                        XCTAssertGreaterThan(frame.height, 0, identifier)
                        XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(frame), identifier)
                        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame), identifier)
                        frames[identifier] = frame
                    }
                    XCTAssertGreaterThan(try XCTUnwrap(frames["approval-subtitle"]).minY,
                                         try XCTUnwrap(frames["approval-allow-once"]).maxY)
                    panel.orderOut(nil)
                }
            }
        }
    }

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

    /// Role-specific AppKit accessibility protocols need not implement the full
    /// NSAccessibility protocol. Traverse the public selectors on every node.
    private func accessibilityElements(_ root: Any) -> [AccessibilityNode] {
        var visited: Set<ObjectIdentifier> = []
        func visit(_ value: Any) -> [AccessibilityNode] {
            guard let object = value as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            let node = AccessibilityNode(object: object)
            return [node] + (node.value("accessibilityChildren") as? [Any] ?? []).flatMap(visit)
        }
        return visit(root)
    }

    private struct AccessibilityNode {
        let object: NSObject
        var identifier: String? { value("accessibilityIdentifier") as? String }
        var frame: CGRect? { (value("accessibilityFrame") as? NSValue)?.rectValue }
        var description: String { "\(type(of: object)):\(identifier ?? "<no identifier>")" }

        func value(_ key: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }
    }
}
