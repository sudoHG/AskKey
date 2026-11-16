import AppKit
import AskKeyBroker
import AskKeyDevices
import Foundation
import SwiftUI
import XCTest
@testable import AskKeyAppKit

/// The approval panel's footer with a paired iPhone (ADR 0014 → Mac App,
/// amended by #345): one moving number at a time in the maintainer's
/// wording (#356), in English and Simplified Chinese, on a fake clock; and
/// deciding later with Esc or VoiceOver now that the footer shows no Esc
/// hint.
@MainActor
final class RemoteApprovalFooterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private var sendAt: Date { start.addingTimeInterval(20) }
    private var expiresAt: Date { start.addingTimeInterval(300) }

    private func footer(_ hint: RemoteApprovalFooterHint?, at seconds: TimeInterval) -> String {
        RemoteApprovalFooter.text(hint, expiresAt: expiresAt, now: start.addingTimeInterval(seconds))
    }

    func testTheSendCountdownRunsFromTwentyToOneThenTheExpiryReturns() {
        ApprovalCardFixtures.withLanguages { language in
            let english = language == "en"
            let waiting = RemoteApprovalFooterHint.waiting(sendAt: sendAt)
            XCTAssertEqual(footer(waiting, at: 0), english
                ? "This request will be sent to iPhone in 20 s"
                : "20 秒后将把审批请求发到 iPhone") // i18n-literal: maintainer's Chinese footer (#356).
            for elapsed in 0..<20 {
                // Each tick falls just after a whole second.
                let seconds = 20 - elapsed
                let expected = english
                    ? "This request will be sent to iPhone in \(seconds) s"
                    : "\(seconds) 秒后将把审批请求发到 iPhone" // i18n-literal: Chinese countdown.
                XCTAssertEqual(footer(waiting, at: Double(elapsed) + 0.01), expected)
                XCTAssertEqual(footer(waiting, at: Double(elapsed) + 0.99), expected)
            }
            XCTAssertEqual(footer(waiting, at: 2), english
                ? "This request will be sent to iPhone in 18 s"
                : "18 秒后将把审批请求发到 iPhone") // i18n-literal: maintainer's Chinese footer (#356).
            XCTAssertEqual(footer(waiting, at: 19.5), english
                ? "This request will be sent to iPhone in 1 s"
                : "1 秒后将把审批请求发到 iPhone") // i18n-literal: Chinese footer at one second.
            // The send is due but not saved yet: the footer shows the expiry.
            XCTAssertEqual(footer(waiting, at: 20), english
                ? "This request expires in 4:40" : "审批请求将于 4:40 后失效") // i18n-literal: Chinese footer.
            XCTAssertEqual(footer(.sent, at: 20.5), english
                ? "This request expires in 4:39"
                : "审批请求将于 4:39 后失效") // i18n-literal: maintainer's Chinese footer (#356).
            XCTAssertEqual(footer(nil, at: 0.5), english
                ? "This request expires in 4:59"
                : "审批请求将于 4:59 后失效") // i18n-literal: maintainer's Chinese footer (#356).
        }
    }

    /// The footer is only its sentence (#356): no Esc hint in any state, and
    /// the pending-request list and the pairing sheet keep their own
    /// "Expires in" wording.
    func testTheFooterDropsTheEscHintAndLeavesTheSharedExpiryWording() {
        ApprovalCardFixtures.withLanguages { language in
            for hint in [RemoteApprovalFooterHint.waiting(sendAt: sendAt), .sent, nil] {
                let text = footer(hint, at: 2)
                XCTAssertFalse(text.contains("Esc"), text)
                XCTAssertFalse(text.contains("·"), text)
            }
            XCTAssertEqual(appLocalizedFormat("Expires in %@", "4:11"), language == "en"
                ? "Expires in 4:11" : "4:11 后失效") // i18n-literal: Chinese shared expiry.
        }
    }

    func testTheFooterNamesNoDeviceAndShowsNoSecondNumber() {
        ApprovalCardFixtures.withLanguages { _ in
            let waiting = RemoteApprovalFooter.text(.waiting(sendAt: sendAt), expiresAt: expiresAt, now: start)
            XCTAssertFalse(waiting.contains(":"), "the expiry gives way to the send countdown: \(waiting)")
            XCTAssertTrue(waiting.contains("iPhone"))
            let sent = RemoteApprovalFooter.text(.sent, expiresAt: expiresAt, now: start)
            XCTAssertTrue(sent.contains("5:00"))
            XCTAssertEqual(sent, RemoteApprovalFooter.text(nil, expiresAt: expiresAt, now: start),
                           "after the send the footer reads as it does without an approver")
        }
    }

    func testTheScheduleTicksJustAfterEachWholeSecondOfTheAnchor() {
        let schedule = RemoteApprovalFooterSchedule(anchor: sendAt)
        let entries = schedule.entries(from: start.addingTimeInterval(2.5), mode: .normal)
        let first = Array(entries.prefix(3)).map { $0.timeIntervalSince(start) }
        XCTAssertEqual(first.count, 3)
        for (index, offset) in first.enumerated() {
            XCTAssertEqual(offset, 2.01 + Double(index), accuracy: 0.000_1)
        }
        ApprovalCardFixtures.withLanguages { language in
            let texts = schedule.entries(from: start.addingTimeInterval(2.5), mode: .normal).prefix(3).map {
                RemoteApprovalFooter.text(.waiting(sendAt: sendAt), expiresAt: expiresAt, now: $0)
            }
            XCTAssertEqual(texts, language == "en"
                ? ["This request will be sent to iPhone in 18 s", "This request will be sent to iPhone in 17 s",
                   "This request will be sent to iPhone in 16 s"]
                : ["18 秒后将把审批请求发到 iPhone", "17 秒后将把审批请求发到 iPhone", "16 秒后将把审批请求发到 iPhone"]) // i18n-literal: Chinese countdown.
        }
        let expiry = RemoteApprovalFooterSchedule(anchor: expiresAt).entries(from: start.addingTimeInterval(0.5), mode: .normal)
        XCTAssertEqual(try XCTUnwrap(expiry.next()).timeIntervalSince(start), 0.01, accuracy: 0.000_1)
        XCTAssertEqual(RemoteApprovalFooter.anchor(.waiting(sendAt: sendAt), expiresAt: expiresAt), sendAt)
        XCTAssertEqual(RemoteApprovalFooter.anchor(.sent, expiresAt: expiresAt), expiresAt)
        XCTAssertEqual(RemoteApprovalFooter.anchor(nil, expiresAt: expiresAt), expiresAt)
    }

    func testThePanelStateFollowsTheCoordinatorUntilTheRequestEnds() {
        let state = RemoteApprovalPanelState(requestID: "request", footer: .waiting(sendAt: sendAt))
        XCTAssertEqual(state.footer, .waiting(sendAt: sendAt))
        func step(ended: Bool = false, unlocked: Bool = true, footer: RemoteApprovalFooterHint?) -> RemoteApprovalPanelState.Step {
            state.step(requestEnded: ended, screenUnlocked: unlocked, expired: false, now: start, status: nil,
                       footer: footer, lastDecision: nil, applying: false)
        }
        XCTAssertEqual(step(footer: nil), .keepOpen)
        XCTAssertNil(state.footer, "a request that stopped being eligible shows the unchanged footer")
        XCTAssertEqual(step(footer: .sent), .keepOpen)
        XCTAssertEqual(state.footer, .sent)
        XCTAssertEqual(step(ended: true, footer: .sent), .close)
        XCTAssertNil(state.footer, "a request that left pending never counts down to a send")
        XCTAssertEqual(step(unlocked: false, footer: .sent), .close, "a lock closes the panel as before")
    }
    func testAnApproversDecisionClearsTheHintAtOnce() {
        let state = RemoteApprovalPanelState(requestID: "request", footer: .sent)
        state.record(RemoteAppliedDecision(requestID: "request", deviceName: "Synthetic iPhone", approved: true), now: start)
        XCTAssertNil(state.footer, "a hint about the approvers never shows next to \"Approved on\"")
        XCTAssertEqual(state.step(requestEnded: false, screenUnlocked: true, expired: false, now: start, status: nil,
                                  footer: .sent, lastDecision: nil, applying: true), .keepOpen)
        XCTAssertNil(state.footer)
    }

    /// The panel follows its state's hint, and a footer that needs a second
    /// line grows the panel downward: its top edge, and with it every button,
    /// stays where it was. Every Chinese form fits on one line.
    func testTheFooterFollowsTheHintAndKeepsTheButtonsInPlace() throws {
        _ = NSApplication.shared
        try ApprovalCardFixtures.withLanguages { language in
            let remote = RemoteApprovalPanelState(requestID: "synthetic", footer: .waiting(sendAt: Date(timeIntervalSinceNow: 18)))
            let panel = makePanel(remote: remote) { _ in XCTFail("Laying out must never decide") }
            defer { panel.contentViewController = nil; panel.close() }
            func show(_ hint: RemoteApprovalFooterHint?) -> NSRect {
                _ = remote.step(requestEnded: false, screenUnlocked: true, expired: false, now: Date(), status: nil,
                                footer: hint, lastDecision: nil, applying: false)
                for _ in 0..<12 {
                    panel.layoutIfNeeded()
                    panel.contentView?.layoutSubtreeIfNeeded()
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
                }
                return panel.frame
            }
            let waiting = show(.waiting(sendAt: Date(timeIntervalSinceNow: 18)))
            let sent = show(.sent)
            let none = show(nil)
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(sent.maxY, waiting.maxY, accuracy: 0.5, "the top edge stays")
            XCTAssertEqual(none.maxY, waiting.maxY, accuracy: 0.5, "the top edge stays")
            XCTAssertEqual(sent.height, none.height, accuracy: 0.5, "both expiry forms take one line")
            if language == "en" {
                XCTAssertGreaterThanOrEqual(waiting.height, none.height - 0.5, "English may wrap, downward")
            } else {
                XCTAssertEqual(waiting.height, none.height, accuracy: 0.5, "every Chinese form fits on one line")
            }
        }
    }

    // MARK: Deciding later

    /// Esc decides later in the production panel (#356) with no control on
    /// the card. The panel takes Esc in `sendEvent(_:)`, through which AppKit
    /// delivers every key event to it, whether the panel itself or the card's
    /// hosting view is first responder (as when keyboard navigation focuses a
    /// button). A cancel sent up the responder chain, as Command-period is,
    /// decides later too. Other keys pass through.
    func testEscInThePanelDecidesLater() throws {
        _ = NSApplication.shared
        var decisions: [BrokerApprovalDecision?] = []
        let remote = RemoteApprovalPanelState(requestID: "synthetic", footer: .waiting(sendAt: Date(timeIntervalSinceNow: 18)))
        let panel = makePanel(remote: remote) { decisions.append($0) }
        defer { panel.contentViewController = nil; panel.close() }
        settle(panel)
        XCTAssertTrue(panel is AgentApprovalPanel)
        let hosting = try XCTUnwrap(panel.contentView)
        for responder in [panel, hosting] as [NSResponder] {
            XCTAssertTrue(panel.makeFirstResponder(responder))
            XCTAssertTrue(panel.firstResponder === responder)
            panel.sendEvent(try key("\u{1b}", code: 53, in: panel))
        }
        XCTAssertEqual(decisions.count, 2, "each Esc reached the card")
        panel.sendEvent(try key("a", code: 0, in: panel))
        panel.sendEvent(try key("\u{1b}", code: 53, modifiers: .command, in: panel))
        XCTAssertEqual(decisions.count, 2, "other keys never decide")
        XCTAssertTrue(hosting.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
        XCTAssertEqual(decisions.count, 3, "a cancel up the responder chain reached the card")
        XCTAssertTrue(decisions.allSatisfy { $0 == nil }, "Esc decides later and never approves or denies")
    }

    /// VoiceOver keeps a way to decide later: the footer is one element
    /// with a "Decide Later" action, named in both languages, that decides
    /// later as Esc does. SwiftUI builds no accessibility tree for a panel
    /// that is never shown, so this checks the footer's wiring and the
    /// action's name; the screenshot flow finds the footer in the real panel.
    func testVoiceOverOffersDecideLaterOnTheFooter() throws {
        ApprovalCardFixtures.withLanguages { language in
            XCTAssertEqual(RemoteApprovalFooter.decideLaterAction, language == "en"
                ? "Decide Later" : "稍后处理") // i18n-literal: Chinese VoiceOver action.
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/AskKeyAppKit/App/FrozenAgentApprovalPrompt.swift"),
                                encoding: .utf8)
        let footer = try XCTUnwrap(source.range(of: "private var footer: some View {")
            .map { String(source[$0.lowerBound...]) })
        XCTAssertTrue(footer.contains(
            ".accessibilityAction(named: Text(verbatim: RemoteApprovalFooter.decideLaterAction)) { finish(nil) }"))
        XCTAssertTrue(footer.contains(".accessibilityIdentifier(\"approval-footer\")"))
        XCTAssertFalse(source.contains(".keyboardShortcut(.cancelAction)"), "Esc is the panel's, not a control's")
    }

    // MARK: Helpers

    private func makePanel(remote: RemoteApprovalPanelState,
                           finish: @escaping (BrokerApprovalDecision?) -> Void) -> NSPanel {
        let request = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
        let prompt = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Staging API",
            expiresAt: Date(timeIntervalSinceNow: 300), timedAllowanceEnabled: true, remote: remote, finish: finish)
        return AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in NSRect(x: 0, y: 0, width: 1440, height: 900) })
    }

    private func settle(_ panel: NSPanel) {
        for _ in 0..<12 {
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     in panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
