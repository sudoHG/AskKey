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

    func testRevokingDisplayedRecordAfterFirstMemberReplacementOnlyRevokesRemainingMembers() throws {
        let machine = makeMachine()
        _ = try grant(machine)
        let displayed = try XCTUnwrap(machine.activeTimedAllowances().first)
        let remainingTicket = try machine.submit(read("b"))
        let remainingLease = try runtimeLease(machine, credentialID: "b")
        defer { remainingLease.finish() }
        let cleaned = expectation(description: "remaining member runtime cleanup")
        try remainingLease.registerCleanup { cleaned.fulfill() }

        let replacement = try machine.submit(read("c"), trustedCredentialDeadline: .none,
            groupAllowanceSnapshot: replacementSnapshot(["a", "c"]))
        _ = try machine.decide(requestID: replacement.requestID, capability: replacement.capability,
                               decision: .timedAllowGroup(duration: 60))
        let newer = try XCTUnwrap(machine.activeTimedAllowances().first { $0.id != displayed.id })
        let newerRead = read("a")
        let newerTicket = try machine.submit(newerRead)
        let newerLease = try runtimeLease(machine, credentialID: "a")
        defer { newerLease.finish() }
        let revoked = expectation(description: "only the remaining member is revoked")
        machine.setTimedAllowanceRevokedHandler { id in
            XCTAssertEqual(id, "b")
            revoked.fulfill()
        }

        XCTAssertTrue(machine.revokeTimedAllowance(id: displayed.id))

        wait(for: [cleaned, revoked], timeout: 1)
        XCTAssertEqual(machine.activeTimedAllowances(), [newer])
        XCTAssertEqual(try machine.status(requestID: remainingTicket.requestID, capability: remainingTicket.capability), .cancelled)
        XCTAssertThrowsError(try remainingLease.performAuthorizedSpawn { XCTFail("The displayed grant was revoked") })
        XCTAssertNoThrow(try machine.consume(requestID: newerTicket.requestID, capability: newerTicket.capability,
                                            operationRequest: newerRead))
        XCTAssertNoThrow(try newerLease.performAuthorizedSpawn {})
        XCTAssertFalse(machine.revokeTimedAllowance(id: displayed.id))
        XCTAssertEqual(try machine.submit(read("b")).state, .pending)
    }

    func testRevokingMissingDisplayedRecordPreservesReplacementTicketsAndRuntimeLeases() throws {
        let machine = makeMachine()
        _ = try grant(machine)
        let displayed = try XCTUnwrap(machine.activeTimedAllowances().first)
        let replacement = try machine.submit(read("c"), trustedCredentialDeadline: .none,
            groupAllowanceSnapshot: replacementSnapshot(["a", "b", "c"]))
        _ = try machine.decide(requestID: replacement.requestID, capability: replacement.capability,
                               decision: .timedAllowGroup(duration: 60))
        let newer = try XCTUnwrap(machine.activeTimedAllowances().first)
        XCTAssertNotEqual(newer.id, displayed.id)
        let newerRead = read("a")
        let newerTicket = try machine.submit(newerRead)
        let newerLease = try runtimeLease(machine, credentialID: "a")
        defer { newerLease.finish() }
        machine.setTimedAllowanceRevokedHandler { _ in XCTFail("A missing record must not revoke any credential") }

        XCTAssertFalse(machine.revokeTimedAllowance(id: displayed.id))

        XCTAssertEqual(machine.activeTimedAllowances(), [newer])
        XCTAssertNoThrow(try machine.consume(requestID: newerTicket.requestID, capability: newerTicket.capability,
                                            operationRequest: newerRead))
        XCTAssertNoThrow(try newerLease.performAuthorizedSpawn {})
        for id in ["a", "b", "c"] { XCTAssertEqual(try machine.submit(read(id)).state, .approved) }
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
            let leases = try ["pause", "disable"].contains(action)
                ? ["a", "b"].map { try runtimeLease(machine, credentialID: $0) } : []
            defer { leases.forEach { $0.finish() } }
            let cleanups = try leases.enumerated().map { index, lease in
                let cleaned = expectation(description: "\(action) cleans member \(index)")
                try lease.registerCleanup { cleaned.fulfill() }
                return cleaned
            }
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
            for lease in leases {
                XCTAssertThrowsError(try lease.performAuthorizedSpawn { XCTFail("\(action) must prevent group launch") })
            }
            if !cleanups.isEmpty { wait(for: cleanups, timeout: 1) }
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

    func testShorterReplacementInvalidatesOlderTimedTicketAndRuntimeLeaseWithoutPriorCancellation() throws {
        let clock = TestClock(start)
        let machine = configuredMachine(clock: { clock.now }, authenticate: { _ in true })
        let original = read("a")
        let ticket = try machine.submit(original, trustedCredentialDeadline: .none,
                                        groupAllowanceSnapshot: replacementSnapshot(["a", "b"]))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                               decision: .timedAllowGroup(duration: 1_800))
        let runtimeRead = read("a")
        let runtimeTicket = try machine.submit(runtimeRead)
        let lease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: runtimeTicket.requestID, capability: runtimeTicket.capability, operationRequest: runtimeRead)
        ]))
        defer { lease.finish() }
        let cleaned = expectation(description: "replacement cleans the older timed runtime lease")
        try lease.registerCleanup { cleaned.fulfill() }
        let expiry = start.addingTimeInterval(60)
        let replacement = try machine.submit(read("c"), trustedCredentialDeadline: .expiresAt(expiry),
            groupAllowanceSnapshot: replacementSnapshot(["a", "b", "c"], expiry: expiry))
        _ = try machine.decide(requestID: replacement.requestID, capability: replacement.capability,
                               decision: .timedAllowGroup(duration: 1_800))
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "a"), expiry)
        XCTAssertEqual(try machine.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
        XCTAssertThrowsError(try lease.validate())
        wait(for: [cleaned], timeout: 1)

        clock.advance(by: 61)
        machine.refreshExpiration()
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        XCTAssertThrowsError(try machine.consumeApproved(requestID: ticket.requestID, capability: ticket.capability,
            operationRequest: original, perform: { XCTFail("An older timed ticket must not deliver after replacement expiry") }))
        XCTAssertThrowsError(try lease.performAuthorizedSpawn { XCTFail("An older timed lease must not launch after replacement expiry") })
        XCTAssertEqual(try machine.submit(read("a")).state, .pending)
    }

    func testReplacementPreservesOnceOnlyTicketsLeasesAndNonoverlappingMembers() throws {
        let clock = TestClock(start)
        let machine = configuredMachine(clock: { clock.now }, authenticate: { _ in true })
        let onceRequest = read("a")
        let onceTicket = try machine.submit(onceRequest)
        _ = try machine.decide(requestID: onceTicket.requestID, capability: onceTicket.capability, decision: .once)
        let onceRuntimeRead = read("a")
        let onceRuntimeTicket = try machine.submit(onceRuntimeRead)
        _ = try machine.decide(requestID: onceRuntimeTicket.requestID, capability: onceRuntimeTicket.capability, decision: .once)
        let onceLease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: onceRuntimeTicket.requestID, capability: onceRuntimeTicket.capability, operationRequest: onceRuntimeRead)
        ]))
        defer { onceLease.finish() }

        let initial = try machine.submit(read("a"), trustedCredentialDeadline: .none,
                                         groupAllowanceSnapshot: replacementSnapshot(["a", "b"]))
        _ = try machine.decide(requestID: initial.requestID, capability: initial.capability, decision: .timedAllowGroup(duration: 1_800))
        let untouchedRequest = read("b")
        let untouchedTicket = try machine.submit(untouchedRequest)
        let untouchedRuntimeRead = read("b")
        let untouchedRuntimeTicket = try machine.submit(untouchedRuntimeRead)
        let untouchedLease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: untouchedRuntimeTicket.requestID, capability: untouchedRuntimeTicket.capability,
                  operationRequest: untouchedRuntimeRead)
        ]))
        defer { untouchedLease.finish() }

        let expiry = start.addingTimeInterval(60)
        let replacement = try machine.submit(read("c"), trustedCredentialDeadline: .expiresAt(expiry),
            groupAllowanceSnapshot: replacementSnapshot(["a", "c"], expiry: expiry))
        _ = try machine.decide(requestID: replacement.requestID, capability: replacement.capability,
                               decision: .timedAllowGroup(duration: 1_800))
        clock.advance(by: 61)
        machine.refreshExpiration()
        XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "b"), start.addingTimeInterval(1_800))
        XCTAssertNoThrow(try machine.consume(requestID: untouchedTicket.requestID, capability: untouchedTicket.capability,
                                            operationRequest: untouchedRequest))
        XCTAssertNoThrow(try untouchedLease.performAuthorizedSpawn {})
        XCTAssertNoThrow(try machine.consume(requestID: onceTicket.requestID, capability: onceTicket.capability,
                                            operationRequest: onceRequest))
        XCTAssertNoThrow(try onceLease.performAuthorizedSpawn {})
    }

    private func replacementSnapshot(_ ids: [String], expiry: Date? = nil) -> BrokerGroupAllowanceSnapshot {
        .init(groupName: "Project", members: ids.map {
            .init(credentialID: $0, name: $0.uppercased(), metadataDigest: digest, expiresAt: $0 == "c" ? expiry : nil)
        })
    }

    private func runtimeLease(_ machine: BrokerApprovalStateMachine, credentialID: String) throws -> BrokerRuntimeReadAuthorization {
        let operation = read(credentialID)
        let ticket = try machine.submit(operation)
        return try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
        ]))
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
