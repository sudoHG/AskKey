import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineDecisionTests: ApprovalStateMachineTestCase {
    func testPendingRequestsExposeConfirmationContextWithoutCredentialValues() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let machine = BrokerApprovalStateMachine(clock: { now })
        let request = BrokerApprovalOperationRequest(
            operationID: String(repeating: "a", count: 64),
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .read,
            payloadDigest: String(repeating: "b", count: 64),
            callerName: "Codex",
            callerPurpose: "Deploy the release"
        )
        let ticket = try machine.submit(request, trustedCredentialDeadline: .none)

        XCTAssertEqual(
            machine.pendingRequests(),
            [BrokerPendingApproval(
                requestID: ticket.requestID,
                capability: ticket.capability,
                request: request,
                expiresAt: now.addingTimeInterval(5 * 60)
            )]
        )
    }
    func testAppCanConfigureApprovalAuthenticationBeforeDecision() throws {
        let machine = BrokerApprovalStateMachine()
        let purposes = AuthenticationRecorder()
        machine.configureAuthentication { purpose in
            purposes.record(purpose)
            return true
        }
        let request = BrokerApprovalOperationRequest(
            operationID: String(repeating: "c", count: 64),
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .read,
            payloadDigest: String(repeating: "d", count: 64)
        )
        let ticket = try machine.submit(request, trustedCredentialDeadline: .none)

        XCTAssertEqual(
            try machine.decide(
                requestID: ticket.requestID,
                capability: ticket.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertEqual(purposes.values, [.readApproval])
    }
    func testRetransmissionReturnsTheExistingCapabilityAndRejectsPayloadSwap() throws {
        let machine = BrokerApprovalStateMachine()
        let request = BrokerApprovalOperationRequest(
            operationID: "operation-1",
            credentialID: "credential-1",
            targetID: "credential-1",
            operation: .read,
            payloadDigest: String(repeating: "a", count: 64)
        )

        let first = try machine.submit(request)
        let retry = try machine.submit(request)

        XCTAssertEqual(first.requestID, retry.requestID)
        XCTAssertEqual(first.capability, retry.capability)
        XCTAssertEqual(first.retryCount, 0)
        XCTAssertEqual(retry.retryCount, 1)
        XCTAssertEqual(retry.state, .pending)
        XCTAssertThrowsError(
            try machine.submit(
                .init(
                    operationID: "operation-1",
                    credentialID: "credential-1",
                    targetID: "credential-1",
                    operation: .read,
                    payloadDigest: String(repeating: "b", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
    }
    func testDenialHasNoCooldownAndOnceApprovalCanOnlyBeConsumedOnce() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let denied = try machine.submit(request(operationID: "operation-denied"))
        XCTAssertEqual(
            try machine.decide(
                requestID: denied.requestID,
                capability: denied.capability,
                decision: .deny
            ).state,
            .denied
        )

        let next = try machine.submit(request(operationID: "operation-next"))
        XCTAssertNotEqual(next.requestID, denied.requestID)
        XCTAssertEqual(next.state, .pending)
        XCTAssertEqual(
            try machine.decide(
                requestID: next.requestID,
                capability: next.capability,
                decision: .once
            ).state,
            .approved
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(
                    operationID: "operation-next",
                    digest: String(repeating: "b", count: 64)
                )
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertEqual(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(operationID: "operation-next")
            ),
            .consumed
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: next.requestID,
                capability: next.capability,
                operationRequest: request(operationID: "operation-next")
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .alreadyConsumed)
        }
    }
    func testPendingRequestExpiresAfterFiveMinutesAndCancellationCannotBeReused() throws {
        let authentications = AuthenticationRecorder()
        let created = Date(timeIntervalSince1970: 1_000)
        let machine = BrokerApprovalStateMachine(clock: { created }, authenticate: {
            authentications.record($0)
            return true
        })
        let expiring = try machine.submit(request(operationID: "expiring"), now: created)

        XCTAssertEqual(
            try machine.status(
                requestID: expiring.requestID,
                capability: expiring.capability,
                now: created.addingTimeInterval(299)
            ),
            .pending
        )
        XCTAssertThrowsError(
            try machine.status(
                requestID: expiring.requestID,
                capability: "wrong-capability",
                now: created
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertEqual(
            try machine.status(
                requestID: expiring.requestID,
                capability: expiring.capability,
                now: created.addingTimeInterval(300)
            ),
            .expired
        )
        XCTAssertThrowsError(
            try machine.decide(
                requestID: expiring.requestID,
                capability: expiring.capability,
                decision: .once,
                now: created.addingTimeInterval(300)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertTrue(authentications.values.isEmpty)

        let cancelled = try machine.submit(request(operationID: "cancelled"), now: created)
        XCTAssertEqual(
            try machine.cancel(
                requestID: cancelled.requestID,
                capability: cancelled.capability,
                now: created
            ),
            .cancelled
        )
        XCTAssertThrowsError(
            try machine.consume(
                requestID: cancelled.requestID,
                capability: cancelled.capability,
                operationRequest: request(operationID: "cancelled")
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
        }
    }
}
