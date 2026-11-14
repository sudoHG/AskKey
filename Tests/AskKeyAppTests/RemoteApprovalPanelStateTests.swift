import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyAppKit

/// The approval panel's privacy check with a paired iPhone (ADR 0014 → Mac
/// App): Details keep where the request went, an approver's decision stays
/// for about two seconds on an unlocked screen, and a lock closes at once.
@MainActor
final class RemoteApprovalPanelStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private let deviceID = DeviceID(rawValue: Data(repeating: 7, count: 16))!

    private func status(sent: Bool = true, delivered: Bool = false) -> RemoteApprovalStatus {
        RemoteApprovalStatus(approvers: [.init(deviceID: deviceID, displayName: "Synthetic iPhone",
                                               sentAt: sent ? start : nil,
                                               deliveredAt: delivered ? start.addingTimeInterval(1) : nil)])
    }

    private func decision(_ requestID: String = "request", approved: Bool = true) -> RemoteAppliedDecision {
        RemoteAppliedDecision(requestID: requestID, deviceName: "Synthetic iPhone", approved: approved)
    }

    private func step(_ state: RemoteApprovalPanelState, ended: Bool = false, unlocked: Bool = true,
                      expired: Bool = false, after seconds: TimeInterval = 0, status: RemoteApprovalStatus? = nil,
                      decision: RemoteAppliedDecision? = nil, applying: Bool = false) -> RemoteApprovalPanelState.Step {
        state.step(requestEnded: ended, screenUnlocked: unlocked, expired: expired, now: start.addingTimeInterval(seconds),
                   status: status, lastDecision: decision, applying: applying)
    }

    func testAPendingRequestStaysOpenAndFollowsDelivery() {
        let state = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(state, status: status()), .keepOpen)
        XCTAssertEqual(state.status, status())
        XCTAssertEqual(step(state, after: 1, status: status(delivered: true)), .keepOpen)
        XCTAssertEqual(state.status, status(delivered: true))
        XCTAssertNil(state.outcome)
    }

    func testAnApproversDecisionStaysForTwoSecondsThenCloses() {
        for approved in [true, false] {
            let state = RemoteApprovalPanelState(requestID: "request", status: status(delivered: true))
            XCTAssertEqual(step(state, ended: true, decision: decision(approved: approved)), .keepOpen)
            XCTAssertEqual(state.outcome, decision(approved: approved))
            XCTAssertEqual(state.status, status(delivered: true), "Details keep where it went after the coordinator drops it")
            XCTAssertEqual(step(state, ended: true, after: 1.9, decision: decision(approved: approved)), .keepOpen)
            XCTAssertEqual(step(state, ended: true, after: 2, decision: decision(approved: approved)), .close)
        }
    }

    func testALockClosesAtOnceEvenWhileTheDecisionShows() {
        let state = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(state, ended: true, decision: decision()), .keepOpen)
        XCTAssertEqual(step(state, ended: true, unlocked: false, after: 0.5, decision: decision()), .close)

        let locked = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(locked, ended: true, unlocked: false, decision: decision()), .close)
        XCTAssertFalse(locked.holdsPanel(screenUnlocked: false, lastDecision: decision(), applying: false))
    }

    func testARequestThatEndedAnotherWayClosesAtOnce() {
        let state = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(state, ended: true, decision: decision("another request")), .close)
        XCTAssertNil(state.outcome, "another request's decision is not this one's")
        XCTAssertEqual(step(RemoteApprovalPanelState(requestID: "request"), expired: true), .close)
        XCTAssertEqual(step(RemoteApprovalPanelState(requestID: "request"), unlocked: false), .close)
    }

    func testTheBrokerMayMoveBeforeTheDecisionIsPublished() {
        let state = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(state, ended: true, applying: true), .keepOpen)
        XCTAssertTrue(state.holdsPanel(screenUnlocked: true, lastDecision: nil, applying: true))
        XCTAssertEqual(step(state, ended: true, after: 0.25, decision: decision()), .keepOpen)
        XCTAssertEqual(state.outcome, decision())
        XCTAssertEqual(step(state, ended: true, after: 2.2, decision: decision()), .keepOpen)
        XCTAssertEqual(step(state, ended: true, after: 2.25, decision: decision()), .close)
    }

    func testADecisionThatLostTheRaceClosesAfterTheGraceAtMost() {
        let state = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(state, ended: true, applying: true), .keepOpen)
        XCTAssertEqual(step(state, ended: true, after: 2.9, applying: true), .keepOpen)
        XCTAssertEqual(step(state, ended: true, after: 3, applying: true), .close)
        let finished = RemoteApprovalPanelState(requestID: "request")
        XCTAssertEqual(step(finished, ended: true, applying: true), .keepOpen)
        XCTAssertEqual(step(finished, ended: true, after: 0.25), .close, "the apply returned without a decision")
    }

    func testTheDecisionIsKeptWhenAnotherOneFollows() {
        let state = RemoteApprovalPanelState(requestID: "request")
        state.record(decision(), now: start)
        state.record(decision("another request", approved: false), now: start.addingTimeInterval(0.1))
        XCTAssertEqual(state.outcome, decision())
        XCTAssertEqual(step(state, ended: true, after: 0.2, decision: decision("another request")), .keepOpen)
        XCTAssertTrue(state.holdsPanel(screenUnlocked: true, lastDecision: decision("another request"), applying: false))
    }
}
