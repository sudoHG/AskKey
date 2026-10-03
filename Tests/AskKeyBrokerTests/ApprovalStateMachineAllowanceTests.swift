import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineAllowanceTests: ApprovalStateMachineTestCase {
    func testVaultLockRevokesEveryTimedAllowance() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let first = try machine.submit(request(operationID: "first"))
        _ = try machine.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .timedAllow(duration: 1_800)
        )

        machine.revokeAllTimedAllowances()

        XCTAssertEqual(try machine.submit(request(operationID: "after-lock")).state, .pending)
    }
    func testTimedAllowanceIsGlobalForOneCredentialReadAndNeverCoversWrites() throws {
        let authentications = AuthenticationRecorder()
        let start = Date(timeIntervalSince1970: 10_000)
        let machine = BrokerApprovalStateMachine(clock: { start }, authenticate: {
            authentications.record($0)
            return true
        })
        let first = try machine.submit(request(operationID: "first"), now: start)
        XCTAssertEqual(
            try machine.decide(
                requestID: first.requestID,
                capability: first.capability,
                decision: .timedAllow(duration: nil),
                now: start
            ).state,
            .approved
        )

        let sameCredential = try machine.submit(
                request(operationID: "same-credential"),
                now: start.addingTimeInterval(1_799)
            )
        XCTAssertEqual(sameCredential.state, .approved)
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "other-credential", credentialID: "credential-2"),
                now: start.addingTimeInterval(1)
            ).state,
            .pending
        )
        let write = try machine.submit(
            request(operationID: "write", operation: .modify),
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(write.state, .pending)
        XCTAssertThrowsError(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .timedAllow(duration: nil),
                now: start.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .once,
                now: start.addingTimeInterval(1)
            ).state,
            .approved
        )
        XCTAssertEqual(authentications.values, [.readApproval, .writeApproval])

        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "credential-1"))
        XCTAssertEqual(
            try machine.status(
                requestID: sameCredential.requestID,
                capability: sameCredential.capability,
                now: start.addingTimeInterval(1_799)
            ),
            .cancelled
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: sameCredential.requestID,
                capability: sameCredential.capability,
                operationRequest: request(operationID: "same-credential"),
                now: start.addingTimeInterval(1_799)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(
            try machine.submit(
                request(operationID: "after-revoke"),
                now: start.addingTimeInterval(2)
            ).state,
            .pending
        )
        let expiryMachine = BrokerApprovalStateMachine(clock: { start }, authenticate: { _ in true })
        let expiryFirst = try expiryMachine.submit(request(operationID: "expiry-first"), now: start)
        _ = try expiryMachine.decide(
            requestID: expiryFirst.requestID,
            capability: expiryFirst.capability,
            decision: .timedAllow(duration: nil),
            now: start
        )
        XCTAssertEqual(
            try expiryMachine.submit(
                request(operationID: "after-expiry"),
                now: start.addingTimeInterval(1_800)
            ).state,
            .pending
        )

        let allowanceClock = TestClock(start)
        let allowanceMachine = BrokerApprovalStateMachine(
            clock: { allowanceClock.now },
            authenticate: { _ in true }
        )
        let allowanceFirst = try allowanceMachine.submit(request(operationID: "short-window"))
        _ = try allowanceMachine.decide(
            requestID: allowanceFirst.requestID,
            capability: allowanceFirst.capability,
            decision: .timedAllow(duration: 60)
        )
        allowanceClock.advance(by: 59)
        let preapproved = try allowanceMachine.submit(request(operationID: "preapproved"))
        XCTAssertEqual(preapproved.state, .approved)
        allowanceClock.advance(by: 1)
        XCTAssertEqual(
            try allowanceMachine.status(
                requestID: preapproved.requestID,
                capability: preapproved.capability
            ),
            .expired
        )
    }
    func testExplicitTimedAllowanceShortensTheCurrentRequestDeadline() throws {
        let start = Date(timeIntervalSince1970: 50_000)
        let clock = TestClock(start)
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let operation = request(operationID: "explicit-short-window")
        let ticket = try machine.submit(operation)
        XCTAssertEqual(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .timedAllow(duration: 60)
            ).state,
            .approved
        )

        clock.advance(by: 60)
        XCTAssertEqual(
            try machine.status(requestID: ticket.requestID, capability: ticket.capability),
            .expired
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: ticket.requestID,
                capability: ticket.capability,
                operationRequest: operation
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }
    func testReadAuthenticationCanBeDisabledButWriteAuthenticationFailsClosed() throws {
        let authentications = AuthenticationRecorder()
        let machine = BrokerApprovalStateMachine(
            readAuthenticationEnabled: false,
            authenticate: {
                authentications.record($0)
                return false
            }
        )
        let read = try machine.submit(request(operationID: "read"))
        XCTAssertEqual(
            try machine.decide(
                requestID: read.requestID,
                capability: read.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertTrue(authentications.values.isEmpty)

        let write = try machine.submit(request(operationID: "write", operation: .delete))
        XCTAssertThrowsError(
            try machine.decide(
                requestID: write.requestID,
                capability: write.capability,
                decision: .once
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(authentications.values, [.writeApproval])
        XCTAssertEqual(
            try machine.status(requestID: write.requestID, capability: write.capability),
            .pending
        )
    }
}
