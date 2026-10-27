import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Hidden panels use the same factory, hosting and observers as live presentation.
@MainActor
final class AgentApprovalScreenLayoutTests: AskKeyAppTestCase {
    func testProductionAllocationPreservesTitleSubtitleActionsAndFooterOnShortScreens() throws {
        _ = NSApplication.shared
        try ApprovalCardFixtures.withLanguages { language in
            for height: CGFloat in [300, 420] {
                for expanded in [false, true] {
                    let request = ApprovalCardFixtures.request(.read,
                        purpose: String(repeating: "Deploy the synthetic staging service. ", count: 40),
                        display: ApprovalCardFixtures.display(environment: (1...48).map { "SYNTHETIC_TOKEN_\($0)" }))
                    let prompt = FrozenAgentApprovalPrompt(request: request,
                        expiresAt: Date().addingTimeInterval(300), timedAllowanceEnabled: true,
                        detailsExpanded: expanded, finish: { _ in XCTFail("Layout never decides a request") })
                    let visible = NSRect(x: 0, y: 0, width: 1024, height: height)
                    let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in visible })
                    defer { panel.contentViewController = nil; panel.close() }
                    layout(panel)
                    let hosting = try XCTUnwrap(panel.contentViewController as? NSHostingController<AgentApprovalPanelContent>)
                    let budget = hosting.rootView.layout.maximumHeight - Theme.Spacing.lg
                    let presentation = prompt.presentation
                    let parts = ApprovalCardPart.allCases
                    let ideals = parts.map {
                        measure(prompt.cardPart($0, presentation: presentation, expanded: expanded))
                    }
                    let regions = zip(parts, ideals).map { pair in pair.0.region(idealHeight: pair.1) }
                    let allocated = ApprovalCardLayout.allocate(regions, maximumHeight: budget)
                    let idealByPart = Dictionary(uniqueKeysWithValues: zip(parts, ideals))
                    let actualByPart = Dictionary(uniqueKeysWithValues: zip(parts, allocated))
                    let context = "\(language), \(height), Details=\(expanded)"
                    let title = measure(prompt.title(presentation.content))
                    let subtitle = measure(prompt.subtitle(presentation.content))
                    XCTAssertGreaterThan(title, 0, context)
                    XCTAssertGreaterThan(subtitle, 0, context)
                    XCTAssertEqual(try XCTUnwrap(idealByPart[.header]), title + subtitle, accuracy: 0.5, context)
                    for part in [ApprovalCardPart.header, .actions, .footer] {
                        XCTAssertGreaterThan(try XCTUnwrap(idealByPart[part]), 0, context)
                        XCTAssertEqual(try XCTUnwrap(actualByPart[part]), try XCTUnwrap(idealByPart[part]),
                                       accuracy: 0.5, "\(context): \(part) keeps its complete ideal height")
                    }
                    XCTAssertTrue(allocated.allSatisfy { $0 >= 0 }, context)
                    XCTAssertLessThanOrEqual(allocated.reduce(0, +), budget + 0.5, context)
                    let iconHeight = try XCTUnwrap(actualByPart[.icon])
                    if ideals.reduce(0, +) > budget {
                        XCTAssertEqual(iconHeight, 0, "\(context): drop the icon before text")
                    } else {
                        XCTAssertEqual(iconHeight, try XCTUnwrap(idealByPart[.icon]), context)
                    }
                    if expanded {
                        XCTAssertLessThan(try XCTUnwrap(actualByPart[.content]), try XCTUnwrap(idealByPart[.content]),
                                          "\(context): long Details scroll instead of squeezing the header")
                    }
                    XCTAssertFalse(panel.isVisible)
                    XCTAssertLessThanOrEqual(panel.frame.height, height + 0.5)
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

    private func measure<V: View>(_ view: V) -> CGFloat {
        let hosting = NSHostingView(rootView: view
            .environment(\.locale, AppLanguage.store.locale)
            .frame(width: FrozenAgentApprovalPrompt.contentWidth)
            .fixedSize(horizontal: false, vertical: true))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame.size = hosting.fittingSize
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func layout(_ panel: NSPanel) {
        let deadline = Date().addingTimeInterval(2)
        for _ in 0..<8 {
            guard Date() < deadline else { return }
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }
}
