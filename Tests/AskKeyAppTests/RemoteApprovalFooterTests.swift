import AppKit
import AskKeyBroker
import AskKeyDevices
import Foundation
import SwiftUI
import XCTest
@testable import AskKeyAppKit

/// The approval panel's footer with a paired iPhone (ADR 0014 → Mac App,
/// amended by #345): one moving number at a time, in English and
/// Simplified Chinese, on a fake clock.
@MainActor
final class RemoteApprovalFooterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private var sendAt: Date { start.addingTimeInterval(20) }
    private var expiresAt: Date { start.addingTimeInterval(300) }

    private func footer(_ hint: RemoteApprovalFooterHint?, at seconds: TimeInterval) -> String {
        RemoteApprovalFooter.sentence(RemoteApprovalFooter.text(hint, expiresAt: expiresAt, now: start.addingTimeInterval(seconds)))
    }

    func testTheSendCountdownRunsFromTwentyToOneThenTheExpiryReturns() {
        ApprovalCardFixtures.withLanguages { language in
            let english = language == "en"
            let waiting = RemoteApprovalFooterHint.waiting(sendAt: sendAt)
            XCTAssertEqual(footer(waiting, at: 0), english
                ? "iPhone can decide in 20 s · Esc to decide later"
                : "20 秒后 iPhone 也能处理 · Esc 稍后处理") // i18n-literal: maintainer's Chinese footer (#344, decision 6).
            for elapsed in 0..<20 {
                // Each tick falls just after a whole second.
                let seconds = 20 - elapsed
                let expected = english ? "iPhone can decide in \(seconds) s" : "\(seconds) 秒后 iPhone 也能处理" // i18n-literal: Chinese countdown.
                XCTAssertEqual(RemoteApprovalFooter.text(waiting, expiresAt: expiresAt,
                                                         now: start.addingTimeInterval(Double(elapsed) + 0.01)), expected)
                XCTAssertEqual(RemoteApprovalFooter.text(waiting, expiresAt: expiresAt,
                                                         now: start.addingTimeInterval(Double(elapsed) + 0.99)), expected)
            }
            XCTAssertEqual(footer(waiting, at: 2), english
                ? "iPhone can decide in 18 s · Esc to decide later"
                : "18 秒后 iPhone 也能处理 · Esc 稍后处理") // i18n-literal: maintainer's Chinese footer (#344, decision 6).
            XCTAssertEqual(footer(waiting, at: 19.5), english
                ? "iPhone can decide in 1 s · Esc to decide later"
                : "1 秒后 iPhone 也能处理 · Esc 稍后处理") // i18n-literal: Chinese footer at one second.
            // The send is due but not saved yet: the footer is unchanged.
            XCTAssertEqual(footer(waiting, at: 20), english
                ? "Expires in 4:40 · Esc to decide later" : "4:40 后失效 · Esc 稍后处理") // i18n-literal: Chinese footer.
            XCTAssertEqual(footer(.sent, at: 20.5), english
                ? "Also on iPhone · Expires in 4:39 · Esc to decide later"
                : "iPhone 也能处理 · 4:39 后失效 · Esc 稍后处理") // i18n-literal: maintainer's Chinese footer (#344, decision 6).
            XCTAssertEqual(footer(nil, at: 0.5), english
                ? "Expires in 4:59 · Esc to decide later" : "4:59 后失效 · Esc 稍后处理") // i18n-literal: Chinese footer.
        }
    }

    func testTheFooterNamesNoDeviceAndShowsNoSecondNumber() {
        ApprovalCardFixtures.withLanguages { _ in
            let waiting = RemoteApprovalFooter.text(.waiting(sendAt: sendAt), expiresAt: expiresAt, now: start)
            XCTAssertFalse(waiting.contains(":"), "the expiry gives way to the send countdown: \(waiting)")
            XCTAssertTrue(waiting.contains("iPhone"))
            let sent = RemoteApprovalFooter.text(.sent, expiresAt: expiresAt, now: start)
            XCTAssertTrue(sent.contains("5:00"))
            XCTAssertTrue(sent.contains("iPhone"))
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
                ? ["iPhone can decide in 18 s", "iPhone can decide in 17 s", "iPhone can decide in 16 s"]
                : ["18 秒后 iPhone 也能处理", "17 秒后 iPhone 也能处理", "16 秒后 iPhone 也能处理"]) // i18n-literal: Chinese countdown.
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
        XCTAssertNil(state.footer, "a request that left pending never says the iPhone can decide")
        XCTAssertEqual(step(unlocked: false, footer: .sent), .close, "a lock closes the panel as before")
    }
    func testAnApproversDecisionClearsTheHintAtOnce() {
        let state = RemoteApprovalPanelState(requestID: "request", footer: .sent)
        state.record(RemoteAppliedDecision(requestID: "request", deviceName: "Synthetic iPhone", approved: true), now: start)
        XCTAssertNil(state.footer, "\"Also on iPhone\" never shows next to \"Approved on\"")
        XCTAssertEqual(state.step(requestEnded: false, screenUnlocked: true, expired: false, now: start, status: nil,
                                  footer: .sent, lastDecision: nil, applying: true), .keepOpen)
        XCTAssertNil(state.footer)
    }

    /// The panel follows its state's hint, and a footer that needs a second
    /// line, as the English sent form does, grows the panel downward: its top
    /// edge, and with it every button, stays where it was.
    func testTheFooterFollowsTheHintAndAGrowingFooterKeepsTheButtonsInPlace() throws {
        _ = NSApplication.shared
        try ApprovalCardFixtures.withLanguages { language in
            let request = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
            let remote = RemoteApprovalPanelState(requestID: "synthetic", footer: .waiting(sendAt: Date(timeIntervalSinceNow: 18)))
            let prompt = FrozenAgentApprovalPrompt(request: request, trustedCredentialName: "Staging API",
                expiresAt: Date(timeIntervalSinceNow: 300), timedAllowanceEnabled: true, remote: remote,
                finish: { _ in XCTFail("Laying out must never decide") })
            let panel = AppDelegate.makeFrozenApprovalPanel(prompt, visibleFrame: { _ in NSRect(x: 0, y: 0, width: 1440, height: 900) })
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
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(sent.maxY, waiting.maxY, accuracy: 0.5, "the top edge stays")
            if language == "en" {
                XCTAssertGreaterThan(sent.height, waiting.height, "the English sent form takes a second line")
            } else {
                XCTAssertEqual(sent.height, waiting.height, accuracy: 0.5, "every Chinese form fits on one line")
            }
            XCTAssertEqual(show(nil), waiting, "the unchanged footer is one line again")
        }
    }
}
