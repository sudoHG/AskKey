import XCTest
@testable import AskKeyBroker

final class TimedAllowanceSessionFenceTests: ApprovalStateMachineTestCase {
    func testOutstandingEndingEventsAreCountedAndResumeCannotClearThem() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        machine.configureTimedAllowanceScreenState { true }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let ticket = try machine.submit(request(operationID: "before-events"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        let first = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
        let second = machine.beginTimedAllowanceSessionEvent(sleeping: true)
        defer { first.finish(); second.finish() }
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        machine.updateTimedAllowanceSession(active: true, endOnLock: false, sleeping: false)
        first.finish()
        first.finish() // Idempotence must not release the second event's fence.
        let pending = try machine.submit(request(operationID: "during-events", credentialID: "fresh"))
        XCTAssertThrowsError(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        second.finish()
        XCTAssertEqual(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved)
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
    }

    func testUnfinishedEventFailsClosedAndErrorDeferReleasesOnlyItsOwnFence() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        machine.configureTimedAllowanceScreenState { true }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let unfinished = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
        defer { unfinished.finish() }
        let pending = try machine.submit(request(operationID: "error-fence"))
        func failedUpdate() throws {
            let event = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
            defer { event.finish() }
            throw BrokerProviderError.requestRejected
        }
        XCTAssertThrowsError(try failedUpdate())
        machine.updateTimedAllowanceSession(active: true, endOnLock: false, sleeping: false)
        XCTAssertThrowsError(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)), "An unfinished event cannot be cleared by another event or an error")
        unfinished.finish()
        XCTAssertEqual(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)).state, .approved, "The error path must not leak its own counter")
    }
}
