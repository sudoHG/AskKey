import XCTest
@testable import AskKeyBroker

final class TimedAllowanceConsumptionSamplingTests: ApprovalStateMachineTestCase {
    func testFailedSampleRefusesEveryTimedConsumptionPathAndPreservesOnceOnlyConsumption() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        for path in ["runtime", "reservation", "explicit-time"] {
            for timed in [false, true] {
                let machine = configuredMachine(clock: { now }, authenticate: { _ in true })
                machine.configureTimedAllowanceScreenState { true }
                machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
                    timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
                let operation = request(operationID: "consumption-\(path)-\(timed)")
                let ticket = try machine.submit(operation)
                _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                    decision: timed ? .timedAllow(duration: 120) : .once)
                let generation = machine.timedAllowanceSessionGeneration
                installRacingProvider(machine)
                let consume = {
                    switch path {
                    case "runtime":
                        let lease = try machine.consumeForRuntime([
                            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
                        ])
                        XCTAssertNotNil(lease)
                        defer { lease?.finish() }
                        try lease?.validate()
                    case "reservation":
                        try machine.consumeApproved(requestID: ticket.requestID, capability: ticket.capability,
                            operationRequest: operation, perform: { XCTAssertFalse(timed, "A timed reservation must not run") })
                    default:
                        // The explicit-time seam reaches consumeApproved(now:).
                        let state = try machine.consume(requestID: ticket.requestID, capability: ticket.capability,
                            operationRequest: operation, now: now)
                        XCTAssertEqual(state, .consumed)
                    }
                }
                if timed {
                    XCTAssertThrowsError(try consume()) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
                    XCTAssertFalse(machine.timedAllowances.isEmpty)
                } else {
                    XCTAssertNoThrow(try consume())
                }
                XCTAssertEqual(machine.entriesByOperationID[operation.operationID]?.state, timed ? .approved : .consumed)
                XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
            }
        }
    }

    func testFailedSampleWithPendingFenceStillRevokesAtTheBackstop() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        machine.configureTimedAllowanceScreenState { true }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let ticket = try machine.submit(request(operationID: "backstop-failure-with-fence"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        installRacingProvider(machine)
        let generation = machine.timedAllowanceSessionGeneration
        let event = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
        defer { event.finish() }
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        XCTAssertNotEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertEqual(machine.entriesByOperationID["backstop-failure-with-fence"]?.state, .cancelled)
    }

    func testFailedSampleWithPendingFenceStillRevokesWhenEnablingThePolicy() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "policy-failure-with-fence"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        installRacingProvider(machine)
        let generation = machine.timedAllowanceSessionGeneration
        let event = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
        defer { event.finish() }
        // The old policy is off, so only policy apply can perform this revocation.
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        XCTAssertTrue(machine.timedAllowances.isEmpty)
        XCTAssertNotEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertEqual(machine.entriesByOperationID["policy-failure-with-fence"]?.state, .cancelled)
    }

    private func installRacingProvider(_ machine: BrokerApprovalStateMachine) {
        machine.configureTimedAllowanceScreenState { [weak machine] in
            if let machine {
                machine.lock.lock()
                machine.timedAllowanceSessionRevision = UUID()
                machine.lock.unlock()
            }
            return true
        }
    }
}
