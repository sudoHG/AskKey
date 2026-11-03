import XCTest
@testable import AskKeyBroker

final class ApprovalStateMachineRuntimeTests: ApprovalStateMachineTestCase {
    func testSettingOnRuntimeRefusesImmediatelyAndDefersReentrantCleanupUntilMutation() throws {
        for spawn in [false, true] {
            let screen = NotificationRecorder()
            let machine = configuredMachine(authenticate: { _ in true })
            machine.configureTimedAllowanceScreenState { screen.counts.isEmpty }
            machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
                timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
            let operation = request(operationID: "backstop-cleanup")
            let ticket = try machine.submit(operation)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
            let lease = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
            ]))
            defer { lease.finish() }
            let cleanups = NotificationRecorder()
            let callbacks = NotificationRecorder()
            machine.setTimedAllowanceRevokedHandler { _ in callbacks.record(count: 1) }
            machine.configureOperationStateChanged { _, _, _ in callbacks.record(count: 2) }
            let cleaned = expectation(description: "screen backstop cleanup can reenter the Broker")
            try lease.registerCleanup {
                _ = machine.pendingRequests()
                cleanups.record(count: 1)
                cleaned.fulfill()
            }
            let revision = machine.stateRevision
            screen.record(count: 1) // No observer or other Broker mutation.
            let finished = expectation(description: "runtime check refuses without cleanup or callbacks")
            DispatchQueue.global().async {
                do {
                    if spawn {
                        try lease.performAuthorizedSpawn { XCTFail("Revoked authority must not spawn") }
                    } else {
                        try lease.validate()
                    }
                    XCTFail("The live backstop must reject timed runtime authority")
                } catch {
                    XCTAssertEqual(error as? BrokerProviderError, .requestRejected)
                }
                finished.fulfill()
            }
            wait(for: [finished], timeout: 2)
            XCTAssertEqual(machine.stateRevision, revision)
            XCTAssertTrue(cleanups.counts.isEmpty)
            XCTAssertTrue(callbacks.counts.isEmpty)
            XCTAssertFalse(machine.timedAllowances.isEmpty)
            _ = machine.pendingRequests()
            wait(for: [cleaned], timeout: 2)
            XCTAssertEqual(cleanups.counts, [1])
            XCTAssertFalse(callbacks.counts.isEmpty)
            machine.configureTimedAllowanceScreenState { true }
            XCTAssertThrowsError(try lease.validate(), "Later unlocked samples must not revive revoked authority")
        }
    }

    func testSettingOffRuntimeValidationPreservesRevisionAndDefersUnrelatedCleanup() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let machine = configuredMachine(clock: { clock.now }, authenticate: { _ in true })
        var leases: [BrokerRuntimeReadAuthorization] = []
        for (credential, decision) in [("live", BrokerApprovalDecision.once), ("expired", .timedAllow(duration: 30))] {
            let operation = request(operationID: credential, credentialID: credential)
            let ticket = try machine.submit(operation)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            leases.append(try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
            ])))
        }
        defer { leases.forEach { $0.finish() } }
        let cleaned = NotificationRecorder()
        try leases[1].registerCleanup {
            // Cleanup must still be allowed to reenter after an ordinary mutation.
            _ = machine.pendingRequests()
            cleaned.record(count: 1)
        }
        machine.flushObservers()
        let revision = machine.stateRevision
        let reportedRevision = machine.reportedRevision
        clock.advance(by: 31)
        XCTAssertNoThrow(try leases[0].validate())
        XCTAssertEqual(try leases[0].performAuthorizedSpawn { "spawned" }, "spawned")
        XCTAssertThrowsError(try leases[0].performAuthorizedSpawn { throw BrokerProviderError.requestRejected })
        XCTAssertThrowsError(try leases[1].validate())
        machine.flushObservers()
        XCTAssertEqual(machine.stateRevision, revision)
        XCTAssertEqual(machine.reportedRevision, reportedRevision)
        XCTAssertTrue(cleaned.counts.isEmpty, "Validation and spawn must not sweep another lease's resources")
        _ = machine.pendingRequests()
        XCTAssertEqual(cleaned.counts, [1])
    }

    func testTimedRevocationUsesEachRuntimeCredentialsApprovalSource() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let once = request(operationID: "once-source", credentialID: "once")
        let timed = request(operationID: "timed-source", credentialID: "timed")
        let onceTicket = try machine.submit(once)
        let timedTicket = try machine.submit(timed)
        _ = try machine.decide(requestID: onceTicket.requestID, capability: onceTicket.capability, decision: .once)
        _ = try machine.decide(requestID: timedTicket.requestID, capability: timedTicket.capability, decision: .timedAllow(duration: 60))
        let authorization = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: onceTicket.requestID, capability: onceTicket.capability, operationRequest: once),
            .init(requestID: timedTicket.requestID, capability: timedTicket.capability, operationRequest: timed)
        ]))
        defer { authorization.finish() }
        let later = try machine.submit(request(operationID: "later-timed-for-once", credentialID: "once"))
        _ = try machine.decide(requestID: later.requestID, capability: later.capability, decision: .timedAllow(duration: 60))
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "once"))
        XCTAssertNoThrow(try authorization.validate(), "The mixed authorization used once-only approval for this credential")
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "timed"))
        XCTAssertThrowsError(try authorization.validate())
    }

    func testConcurrentCountCallbacksCannotPublishAnOlderCountLast() throws {
        let recorder = OrderedCountRecorder()
        let machine = BrokerApprovalStateMachine(
            pendingCountChanged: { recorder.record($0) }
        )
        let firstRequest = request(operationID: "first-callback")
        let firstFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(firstRequest)
            firstFinished.signal()
        }
        XCTAssertEqual(recorder.firstEntered.wait(timeout: .now() + 2), .success)

        let secondRequest = request(operationID: "second-callback")
        let secondFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? machine.submit(secondRequest)
            secondFinished.signal()
        }
        _ = recorder.secondEntered.wait(timeout: .now() + 0.2)
        recorder.releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        machine.flushObservers()

        XCTAssertEqual(recorder.values, [1, 2])
    }
    func testRuntimeAuthorizationSurvivesTicketEvictionButNeverRevocationOrRenewal() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let machine = configuredMachine(clock: { clock.now }, authenticate: { _ in true })
        let original = request(operationID: "runtime-original")
        let ticket = try machine.submit(original)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability,
                               decision: .timedAllow(duration: 30))
        let lease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
        ]))
        defer { lease.finish() }
        for index in 0..<BrokerLimits.maximumRetainedRequestStates {
            let other = try machine.submit(request(operationID: "evict-\(index)", credentialID: "other"))
            _ = try machine.decide(requestID: other.requestID, capability: other.capability, decision: .deny)
        }
        XCTAssertThrowsError(try machine.status(requestID: ticket.requestID, capability: ticket.capability)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertNoThrow(try lease.validate(), "ticket retention does not shorten a live authorization")
        XCTAssertTrue(machine.revokeTimedAllowance(credentialID: "credential-1"))
        XCTAssertThrowsError(try lease.validate())
        let renewed = request(operationID: "runtime-renewed")
        let renewedTicket = try machine.submit(renewed)
        _ = try machine.decide(requestID: renewedTicket.requestID, capability: renewedTicket.capability,
                               decision: .timedAllow(duration: 30))
        let freshLease = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: renewedTicket.requestID, capability: renewedTicket.capability, operationRequest: renewed),
        ]))
        defer { freshLease.finish() }
        XCTAssertNoThrow(try freshLease.validate())
        XCTAssertThrowsError(try lease.validate(), "a new allowance cannot resurrect the evicted old consumption")
    }
    func testRuntimeAuthorizationKeepsItsOriginalDeadlineAndCleanupCanReenterStateMachine() throws {
        for decision in [BrokerApprovalDecision.once, .timedAllow(duration: 30)] {
            let start = Date(timeIntervalSince1970: 10_000)
            let clock = TestClock(start)
            let machine = configuredMachine(requestTTL: 120, defaultTimedAllowance: 30,
                                            clock: { clock.now }, authenticate: { _ in true })
            let original = request(operationID: "original-deadline")
            let ticket = try machine.submit(original)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            let lease = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: original),
            ]))
            defer { lease.finish() }
            let expectedDuration: TimeInterval = decision == .once ? 120 : 30
            XCTAssertEqual(lease.expiresAt, start.addingTimeInterval(expectedDuration))
            let cleaned = expectation(description: "exact authorization deadline cleanup")
            try lease.registerCleanup {
                _ = machine.pendingRequests()
                cleaned.fulfill()
            }
            clock.advance(by: expectedDuration)
            let sweepFinished = expectation(description: "expiry sweep returns after reentrant cleanup")
            DispatchQueue.global().async {
                _ = machine.timedAllowanceDeadline(credentialID: "credential-1")
                sweepFinished.fulfill()
            }
            wait(for: [cleaned, sweepFinished], timeout: 2)
            XCTAssertThrowsError(try lease.validate())
        }
    }
}
