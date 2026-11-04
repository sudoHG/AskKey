import Foundation
import XCTest
@testable import AskKeyAppKit

@MainActor
final class SoftwareUpdateRelaunchPolicyTests: XCTestCase {
    private var activity = SoftwareUpdateActivity.idle
    private var startedTimers = 0
    private var stoppedTimers = 0
    private var tick: (@MainActor () -> Void)?

    private func makeGate() -> SoftwareUpdateRelaunchGate {
        SoftwareUpdateRelaunchGate(
            recheckInterval: 1,
            startTimer: { [unowned self] _, tick in
                self.startedTimers += 1
                self.tick = tick
                return { [unowned self] in self.stoppedTimers += 1 }
            },
            activity: { [unowned self] in self.activity }
        )
    }

    private static let busyStates: [(SoftwareUpdateRelaunchPolicy.Reason, SoftwareUpdateActivity)] = [
        (.pendingApproval, SoftwareUpdateActivity(pendingApprovals: 1)),
        (.unusedApproval, SoftwareUpdateActivity(unusedApprovals: 1)),
        (.runningAgentCall, SoftwareUpdateActivity(runningAgentCalls: 1)),
        (.openWriteSession, SoftwareUpdateActivity(openWriteSessions: 1)),
        (.managementAuthentication, SoftwareUpdateActivity(managementAuthenticationActive: true)),
    ]

    func testIdleAppRelaunchesImmediately() {
        XCTAssertEqual(SoftwareUpdateRelaunchPolicy.reasonsToWait(.idle), [])
        XCTAssertFalse(SoftwareUpdateRelaunchPolicy.mustWait(.idle))

        let gate = makeGate()
        var relaunches = 0
        XCTAssertFalse(gate.postponeIfBusy { relaunches += 1 })
        // Sparkle continues the relaunch itself; the gate keeps nothing.
        XCTAssertEqual(relaunches, 0)
        XCTAssertFalse(gate.isPostponing)
        XCTAssertEqual(startedTimers, 0)
    }

    func testEveryBusyStateNamesItsOwnReason() {
        XCTAssertEqual(Self.busyStates.map(\.0), SoftwareUpdateRelaunchPolicy.Reason.allCases)
        for (reason, state) in Self.busyStates {
            XCTAssertEqual(SoftwareUpdateRelaunchPolicy.reasonsToWait(state), [reason])
            XCTAssertTrue(SoftwareUpdateRelaunchPolicy.mustWait(state), "\(reason)")
        }
        let everything = SoftwareUpdateActivity(
            pendingApprovals: 2, unusedApprovals: 1, runningAgentCalls: 3,
            openWriteSessions: 1, managementAuthenticationActive: true
        )
        XCTAssertEqual(SoftwareUpdateRelaunchPolicy.reasonsToWait(everything), SoftwareUpdateRelaunchPolicy.Reason.allCases)
    }

    func testEachBusyStatePostponesUntilTheAppIsIdle() {
        for (reason, state) in Self.busyStates {
            activity = state
            startedTimers = 0
            stoppedTimers = 0
            let gate = makeGate()
            var relaunches = 0
            XCTAssertTrue(gate.postponeIfBusy { relaunches += 1 }, "\(reason)")
            XCTAssertTrue(gate.isPostponing)
            XCTAssertEqual(startedTimers, 1)

            tick?()
            XCTAssertEqual(relaunches, 0, "still busy: \(reason)")

            activity = .idle
            tick?()
            XCTAssertEqual(relaunches, 1, "\(reason)")
            XCTAssertFalse(gate.isPostponing)
            XCTAssertEqual(stoppedTimers, 1)

            tick?()
            gate.recheck()
            XCTAssertEqual(relaunches, 1, "the relaunch runs once: \(reason)")
        }
    }

    func testRequestArrivingWhilePostponedKeepsTheRelaunchWaiting() {
        let gate = makeGate()
        var relaunches = 0
        activity = SoftwareUpdateActivity(pendingApprovals: 1)
        XCTAssertTrue(gate.postponeIfBusy { relaunches += 1 })

        // The user answers the prompt, and a new run starts before the next check.
        activity = SoftwareUpdateActivity(runningAgentCalls: 1)
        tick?()
        XCTAssertEqual(relaunches, 0)

        // The run's approval is used, and an upload opens.
        activity = SoftwareUpdateActivity(openWriteSessions: 1)
        tick?()
        XCTAssertEqual(relaunches, 0)
        XCTAssertTrue(gate.isPostponing)

        activity = .idle
        tick?()
        XCTAssertEqual(relaunches, 1)
        XCTAssertEqual(startedTimers, 1)
        XCTAssertEqual(stoppedTimers, 1)
    }

    func testRepeatedRequestFromSparkleReplacesTheWaitingRelaunch() {
        let gate = makeGate()
        var first = 0
        var second = 0
        activity = SoftwareUpdateActivity(runningAgentCalls: 1)
        XCTAssertTrue(gate.postponeIfBusy { first += 1 })
        XCTAssertTrue(gate.postponeIfBusy { second += 1 })
        XCTAssertEqual(startedTimers, 1, "one timer for one waiting relaunch")

        activity = .idle
        gate.recheck()
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testRunLoopTimerFiresOnTheMainRunLoopAndStops() {
        let fired = expectation(description: "timer fired")
        var stop: (() -> Void)?
        stop = SoftwareUpdateRelaunchGate.runLoopTimer(interval: 0.01) {
            stop?()
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
    }
}
