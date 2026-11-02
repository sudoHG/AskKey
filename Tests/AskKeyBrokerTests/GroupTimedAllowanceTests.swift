import XCTest
@testable import AskKeyBroker

final class GroupTimedAllowanceTests: ApprovalStateMachineTestCase {
    private let start = Date(timeIntervalSince1970: 10_000)
    private let digest = String(repeating: "b", count: 64)

    func testSnapshotOnlyCoversMatchingReadsAndNeverWrites() throws {
        let machine = makeMachine()
        _ = try grant(machine)
        XCTAssertEqual(machine.activeTimedAllowances().count, 1)
        XCTAssertEqual(machine.activeTimedAllowances().first?.members.map(\.credentialID), ["a", "b"])
        for id in ["a", "b"] { XCTAssertEqual(try machine.submit(read(id), now: start).state, .approved) }
        XCTAssertEqual(try machine.submit(read("added-later"), now: start).state, .pending)
        XCTAssertEqual(try machine.submit(read("b", digest: String(repeating: "c", count: 64)), now: start).state, .pending)
        let write = try machine.submit(request(operationID: "write", credentialID: "b", operation: .modify), now: start)
        XCTAssertEqual(write.state, .pending)
        XCTAssertThrowsError(try machine.decide(requestID: write.requestID, capability: write.capability,
                                               decision: .timedAllowGroup(duration: 60), now: start))
    }

    func testOneGroupDecisionApprovesAlreadyPendingMatchingMembersInTheSameRun() throws {
        let machine = makeMachine()
        let alpha = try submitGroup(machine)
        let beta = try machine.submit(read("b"), now: start)
        let changed = try machine.submit(read("b", digest: String(repeating: "c", count: 64)), now: start)
        let write = try machine.submit(request(operationID: "write", credentialID: "b", operation: .modify), now: start)
        _ = try machine.decide(requestID: alpha.requestID, capability: alpha.capability, decision: .timedAllowGroup(duration: 60))
        XCTAssertEqual(try machine.status(requestID: beta.requestID, capability: beta.capability), .approved)
        XCTAssertEqual(try machine.status(requestID: changed.requestID, capability: changed.capability), .pending)
        XCTAssertEqual(try machine.status(requestID: write.requestID, capability: write.capability), .pending)
    }

    func testMemberMutationWithdrawsOnlyGroupOptionButSubjectMutationCancelsRequest() throws {
        for decision in [BrokerApprovalDecision.once, .timedAllow(duration: 60)] {
            let machine = makeMachine()
            let ticket = try submitGroup(machine)
            machine.cancelPending(credentialID: "b")
            let pending = try XCTUnwrap(machine.pendingRequests().first)
            XCTAssertNil(pending.groupAllowanceSnapshot)
            XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
            XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                  decision: .timedAllowGroup(duration: 60)))
            XCTAssertEqual(try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision).state, .approved)
        }
        let machine = makeMachine()
        let ticket = try submitGroup(machine)
        machine.cancelPending(credentialID: "a")
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
    }

    func testMutationDuringAuthenticationCannotGrantStaleGroup() throws {
        let machine = makeMachine()
        machine.configureAuthentication { _ in machine.cancelPending(credentialID: "b"); return true }
        let ticket = try submitGroup(machine)
        XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                              decision: .timedAllowGroup(duration: 60)))
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
    }

    func testMutationRemovesOnlyMemberAndDoesNotReviveWhenGroupReturns() throws {
        let machine = makeMachine()
        _ = try grant(machine)
        machine.cancelPending(credentialID: "b")
        XCTAssertNil(machine.timedAllowanceDeadline(credentialID: "b"))
        XCTAssertNotNil(machine.timedAllowanceDeadline(credentialID: "a"))
        XCTAssertEqual(try machine.submit(read("b"), now: start).state, .pending)
        XCTAssertEqual(machine.activeTimedAllowances().first?.members.map(\.credentialID), ["a"])
    }

    func testWholeGroupRevocationInvalidatesEveryRuntimeLeaseBeforeLaunch() throws {
        let machine = makeMachine()
        _ = try grant(machine)
        var leases: [BrokerRuntimeReadAuthorization] = []
        defer { leases.forEach { $0.finish() } }
        for id in ["a", "b"] {
            let request = read(id)
            let ticket = try machine.submit(request, now: start)
            let lease = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: request)
            ]))
            let cleaned = expectation(description: "cleanup \(id)")
            try lease.registerCleanup { cleaned.fulfill() }
            leases.append(lease)
        }
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "b"))
        waitForExpectations(timeout: 1)
        for lease in leases {
            XCTAssertThrowsError(try lease.performAuthorizedSpawn { XCTFail("A revoked group must not launch") })
        }
    }

    func testPendingMemberExpiryWithdrawsGroupOptionWithoutCancellingSubject() throws {
        let clock = TestClock(start)
        let machine = configuredMachine(clock: { clock.now }, authenticate: { _ in true })
        let ticket = try submitGroup(machine, expiry: start.addingTimeInterval(20))
        clock.advance(by: 21)
        XCTAssertNil(machine.pendingRequests().first?.groupAllowanceSnapshot)
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 60))
    }

    func testRevokeFromEitherMemberRevokeAllPauseDisableAndExpiryEndEntireRecord() throws {
        for action in ["a", "b", "all", "pause", "disable", "expiry"] {
            let machine = makeMachine()
            _ = try grant(machine)
            let reads = try ["a", "b"].map { try machine.submit(read($0), now: start) }
            switch action {
            case "a", "b": XCTAssertTrue(machine.revokeTimedAllowance(credentialID: action))
            case "all": machine.revokeAllTimedAllowances()
            case "pause": machine.pauseAndCancelAll()
            case "disable": machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: false,
                                                                 timedAllowanceDuration: 1_800)
            default: machine.mutate {
                machine.expireUnconsumedLocked(now: start.addingTimeInterval(61))
                machine.expireTimedAllowancesLocked(now: start.addingTimeInterval(61))
            }
            }
            XCTAssertTrue(machine.activeTimedAllowances().isEmpty, action)
            for ticket in reads {
                XCTAssertNotEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .approved, action)
            }
        }
    }

    func testSharedDeadlineClampsToEarliestMemberExpiryAndOverlapPreservesOtherDeadline() throws {
        let machine = makeMachine()
        _ = try grant(machine, expiry: start.addingTimeInterval(20))
        for id in ["a", "b"] { XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: id), start.addingTimeInterval(20)) }
        let other = try machine.submit(read("a"), now: start)
        // Existing allowance approves this read; a new once-pending card is needed to replace a grant.
        XCTAssertEqual(other.state, .approved)
        machine.cancelPending(credentialID: "a")
        let single = try machine.submit(read("a"), now: start)
        _ = try machine.decide(requestID: single.requestID, capability: single.capability, decision: .timedAllow(duration: 60))
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "b"), start.addingTimeInterval(20))
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "a"), start.addingTimeInterval(60))
    }

    func testGroupDecisionUsesCurrentPolicyAfterAuthentication() throws {
        for enabled in [false, true] {
            let machine = makeMachine()
            let ticket = try submitGroup(machine)
            machine.configureAuthentication { _ in
                machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: enabled,
                                                   timedAllowanceDuration: 15)
                return true
            }
            if enabled {
                _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllowGroup(duration: nil))
                for id in ["a", "b"] { XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: id), start.addingTimeInterval(15)) }
            } else {
                XCTAssertThrowsError(try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                      decision: .timedAllowGroup(duration: nil)))
                XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
                XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
            }
        }
    }

    private func makeMachine() -> BrokerApprovalStateMachine {
        let start = start
        return configuredMachine(clock: { start }, authenticate: { _ in true })
    }

    private func read(_ id: String, digest: String? = nil) -> BrokerApprovalOperationRequest {
        .init(operationID: UUID().uuidString, credentialID: id, targetID: id, operation: .read,
              payloadDigest: String(repeating: "a", count: 64), readProjectionDigest: digest ?? self.digest)
    }

    private func submitGroup(_ machine: BrokerApprovalStateMachine, expiry: Date? = nil) throws -> BrokerApprovalTicket {
        try machine.submit(read("a"), trustedCredentialDeadline: .none, groupAllowanceSnapshot: .init(groupName: "Project", members: [
            .init(credentialID: "a", name: "Alpha", metadataDigest: digest),
            .init(credentialID: "b", name: "Beta", metadataDigest: digest, expiresAt: expiry)
        ]))
    }

    private func grant(_ machine: BrokerApprovalStateMachine, expiry: Date? = nil) throws -> BrokerApprovalTicket {
        let ticket = try submitGroup(machine, expiry: expiry)
        return try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllowGroup(duration: 60))
    }
}
