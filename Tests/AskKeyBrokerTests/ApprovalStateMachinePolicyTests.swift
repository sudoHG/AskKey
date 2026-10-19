import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachinePolicyTests: ApprovalStateMachineTestCase {
    func testDisabledTimedAllowanceRejectsTimedDecisionButAllowsAuthenticatedOnce() throws {
        let machine = BrokerApprovalStateMachine(timedAllowanceEnabled: false, authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "off"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                              decision: .timedAllow(duration: 60))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
        XCTAssertEqual(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once).state, .approved)
    }

    func testTurningTimedAllowanceOffStopsAutomaticApprovalsFromExistingGrant() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "grant"), trustedCredentialDeadline: .none)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 60))
        machine.setTimedAllowanceEnabled(false)
        let next = try machine.submit(request(operationID: "after-off"), trustedCredentialDeadline: .none)
        XCTAssertEqual(next.state, .pending)
        XCTAssertThrowsError(try machine.decide(requestID: next.requestID, capability: next.capability, decision: .timedAllow(duration: nil))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
    }

    func testTurningTimedAllowanceOffDuringAuthenticationRejectsDecision() throws {
        let machine = BrokerApprovalStateMachine()
        machine.configureAuthentication { [weak machine] _ in
            machine?.setTimedAllowanceEnabled(false)
            return true
        }
        let ticket = try machine.submit(request(operationID: "changed-during-auth"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: nil))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
    }

    func testTurningAuthenticationBackOnCannotCommitAnUnauthenticatedReadDecision() throws {
        let machine = BrokerApprovalStateMachine(readAuthenticationEnabled: false, authenticate: { _ in false })
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: false,
                                           timedAllowanceDuration: 1800)
        let ticket = try machine.submit(request(operationID: "authentication-on"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
    }
}
