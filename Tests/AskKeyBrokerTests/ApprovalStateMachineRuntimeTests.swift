import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineRuntimeTests: ApprovalStateMachineTestCase {
    func testConcurrentCountCallbacksCannotPublishAnOlderCountLast() throws {
        let recorder = OrderedCountRecorder()
        let machine = BrokerApprovalStateMachine(
            pendingCountChanged: { recorder.record($0) }
        )
        let firstRequest = request(operationID: "first-callback")
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(firstRequest)
            firstFinished.signal()
        }
        XCTAssertEqual(recorder.firstEntered.wait(timeout: .now() + 2), .success)

        let secondRequest = request(operationID: "second-callback")
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(secondRequest)
            secondFinished.signal()
        }
        _ = recorder.secondEntered.wait(timeout: .now() + 0.2)
        recorder.releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        machine.flushObservers()

        XCTAssertEqual(recorder.values, [1, 2])
    }
    func testRuntimeAuthorizationSurvivesTicketEvictionButNeverRevocationOrRenewal() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let machine = BrokerApprovalStateMachine(clock: { clock.now }, authenticate: { _ in true })
        let original = request(operationID: "runtime-original")
        let ticket = try machine.submit(original)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                               decision: .timedAllow(duration: 30))
        let lease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
        ]))
        defer { lease.finish() }
        for index in 0..<BrokerLimits.maximumRetainedRequestStates {
            let other = try machine.submit(request(operationID: "evict-\(index)", credentialID: "other"))
            _ = try machine.decide(requestID: other.requestID, capability: other.capability, decision: .deny)
        }
        XCTAssertThrowsError(try machine.status(requestID: ticket.requestID, capability: ticket.capability)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertNoThrow(try lease.validate(), "ticket retention does not shorten a live authorization")
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "credential-1"))
        XCTAssertThrowsError(try lease.validate())
        let renewed = request(operationID: "runtime-renewed")
        let renewedTicket = try machine.submit(renewed)
        _ = try machine.decide(requestID: renewedTicket.requestID, capability: renewedTicket.capability,
                               decision: .timedAllow(duration: 30))
        let freshLease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: renewedTicket.requestID, capability: renewedTicket.capability, operationRequest: renewed),
        ]))
        defer { freshLease.finish() }
        XCTAssertNoThrow(try freshLease.validate())
        XCTAssertThrowsError(try lease.validate(), "a new allowance cannot resurrect the evicted old consumption")
    }
    func testRuntimeAuthorizationKeepsItsOriginalDeadlineAndCleanupCanReenterStateMachine() throws {
        for decision in [BrokerApprovalDecision.once, .timedAllow(duration: 30)] {
            let start = Date(timeIntervalSince1970: 10_000)
            let clock = TestClock(start)
            let machine = BrokerApprovalStateMachine(requestTTL: 120, clock: { clock.now }, authenticate: { _ in true })
            let original = request(operationID: "original-deadline")
            let ticket = try machine.submit(original)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            let lease = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
            ]))
            defer { lease.finish() }
            let expectedDuration: TimeInterval = decision == .once ? 120 : 30
            XCTAssertEqual(lease.expiresAt, start.addingTimeInterval(expectedDuration))
            let cleaned = expectation(description: "exact authorization deadline cleanup")
            try lease.registerCleanup {
                _ = machine.pendingRequests()
                cleaned.fulfill()
            }
            clock.advance(by: expectedDuration)
            let sweepFinished = expectation(description: "expiry sweep returns after reentrant cleanup")
            DispatchQueue.global().async {
                _ = machine.timedAllowanceDeadline(credentialID: "credential-1")
                sweepFinished.fulfill()
            }
            wait(for: [cleaned, sweepFinished], timeout: 2)
            XCTAssertThrowsError(try lease.validate())
        }
    }
}
