import XCTest
@testable import AskKeyBroker

/// First decision wins, local or remote, and revocation wins over every
/// decision not yet applied (ADR 0014). Synthetic requests and approvers.
final class RemoteDecisionRaceTests: RemoteApprovalTestCase {
    func testRemoteDecisionAfterALocalDecisionDoesNotMoveTheRequest() throws {
        for local in [BrokerApprovalDecision.deny, .once] {
            let machine = configuredMachine(authenticate: { _ in true })
            let operation = request(operationID: "local-first")
            let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
            let approver = try activate(machine)
            let decided = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: local)
            for code in [BrokerRemoteDecisionCode.deny, .allowOnce] {
                XCTAssertEqual(try remote(machine, ticket, operation, approver, code), .notPending(decided.state, decidedBy: nil))
            }
            XCTAssertEqual(try state(machine, ticket), decided.state)
        }
    }

    func testRemoteDenyAfterExpiryOrCancellationDoesNotMoveTheRequest() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 40_000))
        let machine = configuredMachine(requestTTL: 30, clock: { clock.now })
        let approver = try activate(machine)
        let expiring = request(operationID: "expiring")
        let expiringTicket = try machine.submit(expiring, trustedCredentialDeadline: .none)
        let cancelled = request(operationID: "cancelled", credentialID: "credential-2")
        let cancelledTicket = try machine.submit(cancelled, trustedCredentialDeadline: .none)
        _ = try machine.cancel(requestID: cancelledTicket.requestID, capability: cancelledTicket.capability)
        XCTAssertEqual(try remote(machine, cancelledTicket, cancelled, approver, .deny), .notPending(.cancelled, decidedBy: nil))
        clock.advance(by: 31)
        XCTAssertEqual(try remote(machine, expiringTicket, expiring, approver, .deny), .notPending(.expired, decidedBy: nil))
    }

    func testSecondRemoteDecisionNamesTheApproverThatMovedTheRequest() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "two-approvers")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let first = try activate(machine, phone)
        let second = try activate(machine, tablet, name: "Synthetic Tablet")
        XCTAssertEqual(try remote(machine, ticket, operation, first, .deny), .applied(.denied, grantedSeconds: 0))
        XCTAssertEqual(try remote(machine, ticket, operation, second, .allowOnce), .notPending(.denied, decidedBy: phone))
        XCTAssertEqual(try remote(machine, ticket, operation, first, .deny), .notPending(.denied, decidedBy: phone))
    }

    func testLocalDecisionAfterARemoteDecisionEndsDecidedElsewhere() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let approver = try activate(machine)
        let allowed = request(operationID: "remote-allowed")
        let allowedTicket = try machine.submit(allowed, trustedCredentialDeadline: .none)
        _ = try remote(machine, allowedTicket, allowed, approver, .allowOnce)
        for local in [BrokerApprovalDecision.once, .deny, .timedAllow(duration: 60)] {
            XCTAssertThrowsError(try machine.decide(requestID: allowedTicket.requestID, capability: allowedTicket.capability,
                                                    decision: local)) {
                XCTAssertEqual($0 as? BrokerApprovalError, .decidedElsewhere, "\(local)")
            }
        }
        let denied = request(operationID: "remote-denied", credentialID: "credential-2")
        let deniedTicket = try machine.submit(denied, trustedCredentialDeadline: .none)
        _ = try remote(machine, deniedTicket, denied, approver, .deny)
        XCTAssertThrowsError(try machine.decide(requestID: deniedTicket.requestID, capability: deniedTicket.capability,
                                                decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .decidedElsewhere)
        }
        // A second Deny already returned the denied request before remote approval existed.
        XCTAssertEqual(try machine.decide(requestID: deniedTicket.requestID, capability: deniedTicket.capability,
                                          decision: .deny).state, .denied)
        XCTAssertEqual(try state(machine, allowedTicket), .approved)
    }

    func testOpenLocalAuthenticationEndsDecidedElsewhereWhenARemoteDecisionWins() throws {
        // false: the App's cancellation ended the prompt; true: the person finished it anyway.
        for authenticated in [false, true] {
            let machine = configuredMachine()
            let operation = request(operationID: "open-prompt")
            let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
            let approver = try activate(machine)
            let outcome = LockedOutcome()
            machine.configureAuthentication { [unowned self] _ in
                outcome.value = try? self.remote(machine, ticket, operation, approver, .deny)
                return authenticated
            }
            XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                    decision: .once, revalidate: {})) {
                XCTAssertEqual($0 as? BrokerApprovalError, .decidedElsewhere)
            }
            XCTAssertEqual(outcome.value, .applied(.denied, grantedSeconds: 0))
            XCTAssertEqual(try state(machine, ticket), .denied)
        }
    }

    func testLocalAuthenticationFailureWithoutARemoteDecisionStillFails() throws {
        let machine = configuredMachine(authenticate: { _ in false })
        try activate(machine)
        let ticket = try machine.submit(request(operationID: "local-only"), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(try state(machine, ticket), .pending)
    }

    func testConcurrentLocalAndRemoteDecisionsMoveTheRequestExactlyOnce() throws {
        for index in 0..<50 {
            let machine = configuredMachine(authenticate: { _ in true })
            let operation = request(operationID: "race-\(index)")
            let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
            let approver = try activate(machine)
            let local = LockedDecisionResult()
            let remoteOutcome = LockedOutcome()
            DispatchQueue.concurrentPerform(iterations: 2) { lane in
                if lane == 0 {
                    local.value = Result { try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                              decision: .once).state }
                } else {
                    remoteOutcome.value = try? self.remote(machine, ticket, operation, approver, .deny)
                }
            }
            switch (local.value, remoteOutcome.value) {
            case (.success(.approved)?, .notPending(.approved, decidedBy: nil)?):
                XCTAssertEqual(try state(machine, ticket), .approved)
            case (.failure(let error)?, .applied(.denied, grantedSeconds: 0)?):
                XCTAssertEqual(error as? BrokerApprovalError, .decidedElsewhere)
                XCTAssertEqual(try state(machine, ticket), .denied)
            default:
                XCTFail("Both or neither decision moved the request: \(String(describing: local.value)), \(String(describing: remoteOutcome.value))")
            }
        }
    }

    func testDecisionFromAnInactiveApproverIsRefusedForEveryCode() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "inactive")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let never = BrokerRemoteApprover(pairingID: tablet, generation: 1, deviceName: "Never Added")
        let active = try activate(machine)
        let staleGeneration = BrokerRemoteApprover(pairingID: phone, generation: active.generation + 1, deviceName: "Stale")
        let shortID = BrokerRemoteApprover(pairingID: Data(repeating: 0x31, count: 15), generation: active.generation,
                                           deviceName: "Short")
        for approver in [never, staleGeneration, shortID] {
            for (code, ceiling) in [(BrokerRemoteDecisionCode.deny, 0.0), (.allowOnce, 0), (.timedAllowance, 600)] {
                XCTAssertEqual(try remote(machine, ticket, operation, approver, code, ceiling: ceiling,
                                          revalidate: { XCTFail("Refused before policy I/O") }), .approverInactive)
            }
        }
        machine.removeActiveApprover(pairingID: phone)
        XCTAssertEqual(try remote(machine, ticket, operation, active, .deny), .approverInactive, "Deny included")
        XCTAssertEqual(try state(machine, ticket), .pending)
    }

    func testRemovalThatLandsAfterTheVaultChecksWinsInsideTheLockedTransition() throws {
        for code in [BrokerRemoteDecisionCode.allowOnce, .timedAllowance] {
            let machine = configuredMachine()
            let operation = request(operationID: "suspended")
            let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
            let approver = try activate(machine)
            let entered = DispatchSemaphore(value: 0)
            let resume = DispatchSemaphore(value: 0)
            let outcome = LockedOutcome()
            let finished = expectation(description: "decision returned")
            DispatchQueue.global().async {
                outcome.value = try? self.remote(machine, ticket, operation, approver, code,
                                                 ceiling: code == .timedAllowance ? 600 : 0,
                                                 revalidate: { entered.signal(); resume.wait() })
                finished.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
            machine.removeActiveApprover(pairingID: approver.pairingID)
            resume.signal()
            wait(for: [finished], timeout: 5)
            XCTAssertEqual(outcome.value, .approverInactive)
            XCTAssertEqual(try state(machine, ticket), .pending)
            XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        }
    }

    func testTurningApprovalOffAndOnRefusesDecisionsSealedUnderTheEarlierGeneration() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "re-enabled")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let sealed = try activate(machine)
        machine.removeActiveApprover(pairingID: phone)
        let current = try activate(machine)
        XCTAssertGreaterThan(current.generation, sealed.generation)
        XCTAssertEqual(try remote(machine, ticket, operation, sealed, .allowOnce), .approverInactive)
        XCTAssertEqual(try remote(machine, ticket, operation, sealed, .deny), .approverInactive)
        XCTAssertEqual(try state(machine, ticket), .pending)
        XCTAssertEqual(try remote(machine, ticket, operation, current, .allowOnce), .applied(.approved, grantedSeconds: 0))
    }

    func testEmptyingTheSetRefusesEveryApproverUntilReloaded() throws {
        let machine = configuredMachine()
        let operation = request(operationID: "account-change")
        let ticket = try machine.submit(operation, trustedCredentialDeadline: .none)
        let sealed = try activate(machine)
        machine.removeAllActiveApprovers()
        XCTAssertEqual(try remote(machine, ticket, operation, sealed, .deny), .approverInactive)
        let reloaded = try activate(machine)
        XCTAssertNotEqual(reloaded.generation, sealed.generation, "A reload never revives an earlier generation")
        XCTAssertEqual(try remote(machine, ticket, operation, sealed, .deny), .approverInactive)
        XCTAssertEqual(try state(machine, ticket), .pending)
    }
}

final class LockedOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: BrokerRemoteDecisionOutcome?

    var value: BrokerRemoteDecisionOutcome? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

final class LockedDecisionResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<BrokerRequestState, Error>?

    var value: Result<BrokerRequestState, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
