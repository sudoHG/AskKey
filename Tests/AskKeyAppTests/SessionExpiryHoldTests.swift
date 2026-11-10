import Foundation
import XCTest
@testable import AskKeyAppKit

/// An open pairing sheet holds idle expiry (ADR 0013 → Pairing, step 6).
@MainActor
final class SessionExpiryHoldTests: AskKeyAppTestCase {
    private var timers: [(timeout: Double, timer: Timer)] = []

    override func tearDown() {
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)
        super.tearDown()
    }

    private func makePolicy() -> SessionPolicy {
        SessionPolicy(scheduleTimer: { [unowned self] timeout, callback in
            let timer = Timer(timeInterval: timeout, repeats: false, block: callback)
            timers.append((timeout, timer))
            return timer
        }, enqueueExpiration: { callback in
            MainActor.assumeIsolated { callback() }
        })
    }

    func testHeldExpiryWaitsAndReleasingRestartsTheFullTimeout() {
        let policy = makePolicy()
        defer { policy.cancel() }
        var expired = 0
        policy.renew(timeout: 300) { expired += 1 }
        let first = SessionPolicy.holdIdleExpiry()
        let second = SessionPolicy.holdIdleExpiry()

        timers[0].timer.fire()
        XCTAssertEqual(expired, 0)
        first.release()
        first.release()
        XCTAssertEqual(timers.count, 1, "another hold is still open")
        second.release()
        XCTAssertEqual(timers.count, 2)
        XCTAssertEqual(timers[1].timeout, 300)
        timers[1].timer.fire()
        XCTAssertEqual(expired, 1)
    }

    func testWithoutAHoldExpiryIsUnchangedAndACancelledPolicyIsNotRestarted() {
        let policy = makePolicy()
        var expired = 0
        policy.renew(timeout: 60) { expired += 1 }
        timers[0].timer.fire()
        XCTAssertEqual(expired, 1)

        policy.renew(timeout: 60) { expired += 1 }
        let hold = SessionPolicy.holdIdleExpiry()
        timers[1].timer.fire()
        policy.cancel()
        hold.release()
        XCTAssertEqual(timers.count, 2, "a cancelled session is not restarted")
        XCTAssertEqual(expired, 1)
    }

    func testRenewingDuringAHoldReplacesTheWaitingExpiry() {
        let policy = makePolicy()
        defer { policy.cancel() }
        var expired: [String] = []
        policy.renew(timeout: 60) { expired.append("old") }
        let hold = SessionPolicy.holdIdleExpiry()
        timers[0].timer.fire()
        policy.renew(timeout: 120) { expired.append("new") }
        hold.release()
        XCTAssertEqual(timers.count, 2, "the renewed timer is still running; nothing restarts")
        timers[1].timer.fire()
        XCTAssertEqual(expired, ["new"])
    }
}
