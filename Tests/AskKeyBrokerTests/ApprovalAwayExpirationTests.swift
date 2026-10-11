import Foundation
import XCTest
@testable import AskKeyBroker

final class ApprovalAwayExpirationTests: ApprovalStateMachineTestCase {
    func testWakeRefreshExpiresPausedTimerRequestsAndUpdatesObservers() throws {
        let clock = Clock()
        let counts = Counts()
        let machine = BrokerApprovalStateMachine(clock: { clock.now }, pendingCountChanged: { counts.append($0) })
        machine.expirationTimer.suspend()
        defer { machine.expirationTimer.resume() }
        let ticket = try machine.submit(request(operationID: "away"))
        machine.flushObservers()
        XCTAssertEqual(counts.values, [1])
        clock.advance(301)
        machine.flushObservers()
        XCTAssertEqual(counts.values, [1], "No timer event or broker call refreshed the badge")
        machine.refreshExpiration()
        machine.flushObservers()
        XCTAssertEqual(counts.values, [1, 0])
        XCTAssertTrue(machine.pendingRequests().isEmpty)
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .expired)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once))
    }

    func testResumeBeforeDeadlineDoesNotExtendOrEndRequest() throws {
        let clock = Clock()
        let machine = BrokerApprovalStateMachine(clock: { clock.now })
        let ticket = try machine.submit(request(operationID: "brief-away"))
        clock.advance(30)
        machine.refreshExpiration()
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        clock.advance(270)
        machine.refreshExpiration()
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .expired)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 2_000_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
    }
    private final class Counts: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Int] = []
        var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
        func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    }
}
