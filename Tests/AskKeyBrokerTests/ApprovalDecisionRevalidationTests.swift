import XCTest
@testable import AskKeyBroker

final class ApprovalDecisionRevalidationTests: ApprovalStateMachineTestCase {
    func testRevalidationRunsAfterAuthenticationOutsideApprovalLock() throws {
        let authentication = AuthenticationRecorder()
        let machine = configuredMachine(authenticate: { authentication.record($0); return true })
        let ticket = try machine.submit(request(operationID: "pause-during-auth"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once,
            revalidate: {
                XCTAssertEqual(authentication.values, [.readApproval])
                machine.pauseAndCancelAll()
            }
        )) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
    }

    func testFailedRevalidationAppliesNoDecisionOrTimedAllowance() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "failed-revalidation"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 60),
            revalidate: { throw BrokerApprovalError.invalidDecision }
        ))
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
    }

    func testRevalidationCannotBypassAuthenticationOrStateMachinePolicy() throws {
        let machine = configuredMachine(authenticate: { _ in false })
        let ticket = try machine.submit(request(operationID: "authentication-required"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once,
            revalidate: { XCTFail("Authentication must still run first") }
        )) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
    }

    func testExpirationDuringPersistedPolicyCheckCannotApproveRequest() throws {
        let clock = TestClock(Date())
        let machine = configuredMachine(requestTTL: 30, clock: { clock.now }, authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "expires-during-check"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once,
            revalidate: { clock.advance(by: 31) }
        ))
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .expired)
    }
}
