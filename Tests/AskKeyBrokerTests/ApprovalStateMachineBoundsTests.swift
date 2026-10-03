import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineBoundsTests: ApprovalStateMachineTestCase {
    func testExternalFieldsAndPendingQueueAreBounded() throws {
        let machine = BrokerApprovalStateMachine()
        XCTAssertThrowsError(
            try machine.submit(request(operationID: ""))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "wrong-modify-target",
                    credentialID: "credential-1",
                    targetID: "credential-2",
                    operation: .modify,
                    payloadDigest: String(repeating: "a", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "wrong-read-target",
                    credentialID: "credential-1",
                    targetID: "credential-2",
                    operation: .read,
                    payloadDigest: String(repeating: "a", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try machine.submit(
                request(
                    operationID: "oversized",
                    digest: String(repeating: "x", count: BrokerLimits.maximumFieldBytes + 1)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }

        var first: BrokerApprovalTicket?
        for index in 0..<BrokerLimits.maximumPendingApprovalRequests {
            let ticket = try machine.submit(request(operationID: "operation-\(index)"))
            if first == nil { first = ticket }
        }
        XCTAssertThrowsError(
            try machine.submit(request(operationID: "overflow"))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .capacityReached)
        }
        guard let first else { return XCTFail("expected the first pending request") }
        _ = try machine.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .deny
        )
        XCTAssertNoThrow(try machine.submit(request(operationID: "replacement")))

        let allowedMachine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let allowance = try allowedMachine.submit(request(operationID: "allowance"))
        _ = try allowedMachine.decide(
            requestID: allowance.requestID,
            capability: allowance.capability,
            decision: .timedAllow(duration: nil)
        )
        for index in 0..<(BrokerLimits.maximumPendingApprovalRequests - 1) {
            _ = try allowedMachine.submit(
                request(operationID: "other-\(index)", credentialID: "other-\(index)")
            )
        }
        XCTAssertThrowsError(
            try allowedMachine.submit(request(operationID: "allowed-despite-full-queue"))
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .capacityReached)
        }
    }
    func testApprovedRequestExpiresAndAuthenticationCannotCrossTheDeadline() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 30_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in
                clock.advance(by: 300)
                return true
            }
        )
        let slowRequest = request(operationID: "slow-auth")
        let ticket = try machine.submit(slowRequest, now: clock.now)

        XCTAssertThrowsError(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .once,
                now: Date(timeIntervalSince1970: 30_000)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.status(requestID: ticket.requestID, capability: ticket.capability, now: clock.now),
            .expired
        )

        let approvedMachine = BrokerApprovalStateMachine(clock: { clock.now }, authenticate: { _ in true })
        let approvedRequest = request(operationID: "approved-expiry")
        let approved = try approvedMachine.submit(approvedRequest, now: clock.now)
        _ = try approvedMachine.decide(
            requestID: approved.requestID,
            capability: approved.capability,
            decision: .once,
            now: clock.now
        )
        clock.advance(by: 300)
        XCTAssertEqual(
            try approvedMachine.status(
                requestID: approved.requestID,
                capability: approved.capability,
                now: clock.now
            ),
            .expired
        )
        XCTAssertThrowsError(
            try approvedMachine.consume(
                requestID: approved.requestID,
                capability: approved.capability,
                operationRequest: approvedRequest,
                now: clock.now
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }

        let rollbackClock = TestClock(Date(timeIntervalSince1970: 40_000))
        let rollbackMachine = BrokerApprovalStateMachine(
            clock: { rollbackClock.now },
            authenticate: { _ in true }
        )
        let rollbackRequest = request(operationID: "rollback")
        let rollback = try rollbackMachine.submit(rollbackRequest, now: rollbackClock.now)
        _ = try rollbackMachine.decide(
            requestID: rollback.requestID,
            capability: rollback.capability,
            decision: .once,
            now: rollbackClock.now
        )
        rollbackClock.advance(by: 300)
        XCTAssertThrowsError(
            try rollbackMachine.consume(
                requestID: rollback.requestID,
                capability: rollback.capability,
                operationRequest: rollbackRequest
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }
}
