import XCTest
@testable import AskKeyBroker

final class TimedAllowanceScreenSamplingTests: ApprovalStateMachineTestCase {
    func testEveryLiveSampleIncludingPolicyEnableAndReplacementRunsOutsideApprovalLock() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let probe = SamplingProbe()
        machine.configureTimedAllowanceScreenState { [weak machine] in
            if let machine {
                let acquired = machine.lock.try()
                XCTAssertTrue(acquired, "WindowServer sampling must not hold the approval lock")
                if acquired { machine.lock.unlock() }
            }
            return probe.sample()
        }
        XCTAssertEqual(probe.reads, 0)
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let ticket = try machine.submit(request(operationID: "sample-outside-lock"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        XCTAssertNotNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
        machine.configureTimedAllowanceScreenState { [weak machine] in
            if let machine {
                let acquired = machine.lock.try()
                XCTAssertTrue(acquired)
                if acquired { machine.lock.unlock() }
            }
            return false
        }
        XCTAssertTrue(machine.timedAllowances.isEmpty, "Replacing the provider must use its new sample immediately")
    }

    func testLockReceivedDuringUnlockedSampleCannotGrantOrConsumeTimedAuthority() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let probe = SamplingProbe()
        machine.configureTimedAllowanceScreenState { probe.sample() }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let operation = request(operationID: "cached-before-sampling")
        let ticket = try machine.submit(operation)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        probe.blockNextSample()
        let finished = expectation(description: "stale unlocked sample rejected")
        DispatchQueue.global().async {
            do {
                _ = try machine.consumeForRuntime([
                    .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
                ])
                XCTFail("A lock received during sampling must refuse timed consumption")
            } catch {
                XCTAssertEqual(error as? BrokerApprovalError, .invalidDecision)
            }
            finished.fulfill()
        }
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 2), .success)
        let event = machine.beginTimedAllowanceSessionEvent(sleeping: nil)
        defer { event.finish() }
        probe.release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(machine.activeTimedAllowances().isEmpty)
        let pending = try machine.submit(request(operationID: "pending-during-fence", credentialID: "fresh"))
        XCTAssertThrowsError(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        XCTAssertEqual(try machine.status(requestID: pending.requestID, capability: pending.capability), .pending)
    }

    func testOrdinaryConcurrentMutationsDoNotInvalidateUnlockedSamplesOrRevokeAuthority() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let probe = SamplingProbe()
        machine.configureTimedAllowanceScreenState { probe.sample() }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let ticket = try machine.submit(request(operationID: "before-ordinary-contention"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        let deadline = machine.timedAllowanceDeadline(credentialID: "credential-1")
        let generation = machine.timedAllowanceSessionGeneration
        let reads = probe.reads
        probe.blockNextSample()
        let finished = expectation(description: "ordinary contention preserves the unlocked sample")
        DispatchQueue.global().async {
            XCTAssertEqual(machine.timedAllowanceDeadline(credentialID: "credential-1"), deadline)
            finished.fulfill()
        }
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 2), .success)
        _ = machine.pendingRequests()
        _ = machine.activeTimedAllowances()
        probe.release.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(probe.reads - reads, 3, "Read-only mutations must not force another screen sample")
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertFalse(machine.timedAllowances.isEmpty)
        XCTAssertNil(machine.timedAllowanceScreenSample)
        XCTAssertFalse(machine.timedAllowanceScreenSampleFailed)
    }

    func testRepeatedSessionRacesRefuseOnlyThisOperationWithoutRevokingAllowances() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "before-contention"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let generation = machine.timedAllowanceSessionGeneration
        let probe = SamplingProbe()
        machine.configureTimedAllowanceScreenState { [weak machine] in
            if let machine {
                // Model a session configuration change completing during each sample.
                machine.lock.lock()
                machine.timedAllowanceSessionRevision = UUID()
                machine.lock.unlock()
            }
            return probe.sample()
        }
        XCTAssertEqual(probe.reads, 2, "Only one sampling retry is permitted")
        XCTAssertFalse(machine.timedAllowances.isEmpty)
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        let before = probe.reads
        XCTAssertNotNil(machine.timedAllowanceDeadline(credentialID: "credential-1"))
        XCTAssertEqual(probe.reads - before, 2)
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertFalse(machine.timedAllowances.isEmpty, "A failed policy-apply sample must not revoke globally either")
        let pending = try machine.submit(request(operationID: "sample-race-submission"))
        XCTAssertEqual(pending.state, .pending, "A failed sample must not auto-approve from a surviving allowance")
        XCTAssertThrowsError(try machine.decide(requestID: pending.requestID, capability: pending.capability,
            decision: .timedAllow(duration: 120)))
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertFalse(machine.timedAllowances.isEmpty)
        XCTAssertNil(machine.timedAllowanceScreenSample)
        XCTAssertFalse(machine.timedAllowanceScreenSampleFailed)
        machine.configureTimedAllowanceScreenState { true }
        XCTAssertEqual(try machine.submit(request(operationID: "stable-sample-submission")).state, .approved)
    }

    func testFenceBeginAndFinishInsideOneSampleStillInvalidatesThatSample() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let ticket = try machine.submit(request(operationID: "before-fence-roundtrip"))
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .timedAllow(duration: 120))
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let generation = machine.timedAllowanceSessionGeneration
        let reads = SamplingProbe()
        machine.configureTimedAllowanceScreenState { [weak machine] in
            let event = machine?.beginTimedAllowanceSessionEvent(sleeping: nil)
            event?.finish()
            return reads.sample()
        }
        XCTAssertEqual(reads.reads, 2)
        let pending = try machine.submit(request(operationID: "fence-roundtrip-submission"))
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertFalse(machine.timedAllowances.isEmpty)
    }
}

private final class SamplingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var blockNext = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }

    func blockNextSample() { lock.lock(); blockNext = true; lock.unlock() }

    func sample() -> Bool {
        lock.lock()
        count += 1
        let block = blockNext
        blockNext = false
        lock.unlock()
        if block {
            entered.signal()
            XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
        }
        return true
    }
}
