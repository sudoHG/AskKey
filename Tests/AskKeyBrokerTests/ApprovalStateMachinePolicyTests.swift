import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachinePolicyTests: ApprovalStateMachineTestCase {
    func testTimedAllowanceStartsDisabledUntilPolicyIsApplied() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "restrictive-default"), trustedCredentialDeadline: .none)

        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .timedAllow(duration: 900)
        )) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))

        machine.configureAgentAccessPolicy(
            readAuthenticationEnabled: true,
            timedAllowanceEnabled: true,
            timedAllowanceDuration: 900
        )
        let enabled = try machine.submit(request(operationID: "after-policy"), trustedCredentialDeadline: .none)
        XCTAssertNoThrow(try machine.decide(
            requestID: enabled.requestID,
            capability: enabled.capability,
            decision: .timedAllow(duration: 900)
        ))
    }

    func testDisplayedDurationRemainsTheMaximumWhenDefaultChangesDuringAuthentication() throws {
        let start = Date(timeIntervalSince1970: 70_000)
        let machine = configuredMachine(defaultTimedAllowance: 900, clock: { start }, authenticate: { _ in true })
        machine.configureAuthentication { [weak machine] _ in
            machine?.configureAgentAccessPolicy(
                readAuthenticationEnabled: true,
                timedAllowanceEnabled: true,
                timedAllowanceDuration: 7_200
            )
            return true
        }
        let ticket = try machine.submit(request(operationID: "displayed-fifteen-minutes"), now: start)

        _ = try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .timedAllow(duration: 15 * 60),
            now: start
        )

        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "credential-1"), start.addingTimeInterval(15 * 60))
    }

    func testExplicitTimedAllowanceCapsAtTwoHoursAndAcceptsTheBoundary() throws {
        let start = Date(timeIntervalSince1970: 75_000)
        let machine = configuredMachine(clock: { start }, authenticate: { _ in true })
        machine.updateDefaultTimedAllowance(120 * 60)

        let atMaximum = try machine.submit(request(operationID: "at-two-hours"), now: start)
        _ = try machine.decide(
            requestID: atMaximum.requestID,
            capability: atMaximum.capability,
            decision: .timedAllow(duration: 7_200),
            now: start
        )
        XCTAssertEqual(
            machine.timedAllowanceDeadline(credentialID: "credential-1"),
            start.addingTimeInterval(7_200)
        )

        let aboveMaximum = try machine.submit(
            request(operationID: "above-two-hours", credentialID: "credential-2"),
            now: start
        )
        _ = try machine.decide(
            requestID: aboveMaximum.requestID,
            capability: aboveMaximum.capability,
            decision: .timedAllow(duration: 7_201),
            now: start
        )
        XCTAssertEqual(
            machine.timedAllowanceDeadline(credentialID: "credential-2"),
            start.addingTimeInterval(7_200)
        )

        for (index, invalidDuration) in [0, -1, .infinity, .nan].enumerated() {
            let credentialID = "invalid-\(index)"
            let invalid = try machine.submit(
                request(operationID: "invalid-duration-\(index)", credentialID: credentialID),
                now: start
            )
            XCTAssertThrowsError(try machine.decide(
                requestID: invalid.requestID,
                capability: invalid.capability,
                decision: .timedAllow(duration: invalidDuration),
                now: start
            )) {
                XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
            }
        }
    }

    func testNilDurationUsesPolicyDurationCapturedBeforeAuthentication() throws {
        let start = Date(timeIntervalSince1970: 80_000)
        let machine = configuredMachine(defaultTimedAllowance: 900, clock: { start }, authenticate: { _ in true })
        machine.configureAuthentication { [weak machine] _ in
            machine?.configureAgentAccessPolicy(
                readAuthenticationEnabled: true,
                timedAllowanceEnabled: true,
                timedAllowanceDuration: 7_200
            )
            return true
        }
        let ticket = try machine.submit(request(operationID: "captured-default"), now: start)

        _ = try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .timedAllow(duration: nil),
            now: start
        )

        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "credential-1"), start.addingTimeInterval(15 * 60))
    }

    func testDisablingPolicyDuringAuthenticationRejectsTheTimedDecision() throws {
        let start = Date(timeIntervalSince1970: 85_000)
        let machine = configuredMachine(defaultTimedAllowance: 900, clock: { start }, authenticate: { _ in true })
        machine.configureAuthentication { [weak machine] _ in
            machine?.configureAgentAccessPolicy(
                readAuthenticationEnabled: true,
                timedAllowanceEnabled: false,
                timedAllowanceDuration: 900
            )
            return true
        }
        let ticket = try machine.submit(request(operationID: "disabled-during-auth"), now: start)

        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .timedAllow(duration: 900),
            now: start
        )) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
    }

    func testDisablingPolicyRevokesWindowsApprovedRequestsAndRuntimeLeases() throws {
        let start = Date(timeIntervalSince1970: 90_000)
        let callbacks = TimedAllowanceRevocationRecorder()
        let machine = configuredMachine(
            clock: { start },
            authenticate: { _ in true },
            timedAllowanceRevoked: { callbacks.record($0) }
        )

        let original = try machine.submit(request(operationID: "first-grant"), now: start)
        _ = try machine.decide(requestID: original.requestID, capability: original.capability,
                               decision: .timedAllow(duration: 900), now: start)
        let preapproved = try machine.submit(request(operationID: "unconsumed-preapproval"), now: start)
        XCTAssertEqual(preapproved.state, .approved)

        let runtimeRequest = request(operationID: "runtime-grant", credentialID: "credential-2")
        let runtimeTicket = try machine.submit(runtimeRequest, now: start)
        _ = try machine.decide(requestID: runtimeTicket.requestID, capability: runtimeTicket.capability,
                               decision: .timedAllow(duration: 900), now: start)
        let lease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: runtimeTicket.requestID, capability: runtimeTicket.capability,
                  operationRequest: runtimeRequest),
        ]))
        let cleanup = expectation(description: "runtime lease cleanup on policy disable")
        try lease.registerCleanup { cleanup.fulfill() }

        machine.configureAgentAccessPolicy(
            readAuthenticationEnabled: true,
            timedAllowanceEnabled: false,
            timedAllowanceDuration: 900
        )

        wait(for: [cleanup], timeout: 2)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-2"))
        XCTAssertEqual(try machine.status(requestID: original.requestID, capability: original.capability), .cancelled)
        XCTAssertEqual(try machine.status(requestID: preapproved.requestID, capability: preapproved.capability), .cancelled)
        XCTAssertThrowsError(try lease.validate())
        XCTAssertEqual(callbacks.values.sorted(), ["credential-1", "credential-2"])

        machine.configureAgentAccessPolicy(
            readAuthenticationEnabled: true,
            timedAllowanceEnabled: true,
            timedAllowanceDuration: 900
        )
        XCTAssertEqual(try machine.submit(request(operationID: "credential-1-again"), now: start).state, .pending)
        XCTAssertEqual(try machine.submit(request(operationID: "credential-2-again", credentialID: "credential-2"), now: start).state,
                       .pending)
    }

    func testTurningAuthenticationBackOnCannotCommitAnUnauthenticatedReadDecision() throws {
        let machine = BrokerApprovalStateMachine(readAuthenticationEnabled: false, authenticate: { _ in false })
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: false,
                                           timedAllowanceDuration: 1_800)
        let ticket = try machine.submit(request(operationID: "authentication-on"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
    }
}

private final class TimedAllowanceRevocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ credentialID: String) {
        lock.lock()
        recorded.append(credentialID)
        lock.unlock()
    }
}
