import XCTest
@testable import AskKeyBroker

final class TimedAllowanceRuntimeGateTests: ApprovalStateMachineTestCase {
    func testSettingOnOnceRuntimeValidationAndSpawnMakeZeroProviderReads() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let reads = NotificationRecorder()
        machine.configureTimedAllowanceScreenState { reads.record(count: 1); return true }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let operation = request(operationID: "once-runtime-with-provider")
        let ticket = try machine.submit(operation)
        _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        let runtime = try XCTUnwrap(machine.consumeForRuntime([
            .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
        ]))
        defer { runtime.finish() }
        let lease = BrokerTextDeliveryLease(beginSpawnAuthorization: {}, validate: {}, endSpawnAuthorization: {},
            spawnDeadline: nil, runtimeAuthorization: runtime, finish: {})
        defer { lease.finish(); lease.cleanup() }
        let before = reads.counts.count
        XCTAssertGreaterThan(before, 0, "The provider must be installed and exercised before the runtime check")
        XCTAssertNoThrow(try runtime.validate())
        XCTAssertEqual(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { "spawned" }), "spawned")
        XCTAssertEqual(reads.counts.count, before)
    }

    func testSettingOffRuntimeWithConfiguredProviderMakesZeroProviderReads() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        let reads = NotificationRecorder()
        machine.configureTimedAllowanceScreenState { reads.record(count: 1); return false }
        for (credential, decision) in [("off-once", BrokerApprovalDecision.once), ("off-timed", .timedAllow(duration: 120))] {
            let operation = request(operationID: credential, credentialID: credential)
            let ticket = try machine.submit(operation)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            let runtime = try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
            ]))
            XCTAssertNoThrow(try runtime.validate())
            XCTAssertEqual(try runtime.performAuthorizedSpawn { "spawned" }, "spawned")
            runtime.finish()
        }
        XCTAssertTrue(reads.counts.isEmpty)
    }

    func testSettingOnOnceSpawnSurvivesFailedSampleWithoutCallbacksOrCleanupInsideGate() throws {
        let machine = configuredMachine(authenticate: { _ in true })
        machine.configureTimedAllowanceScreenState { true }
        machine.configureAgentAccessPolicy(readAuthenticationEnabled: true, timedAllowanceEnabled: true,
            timedAllowanceDuration: 1_800, endTimedAllowancesOnLock: true)
        let gate = RuntimeGateProbe()
        let callbacks = NotificationRecorder()
        var authorizations: [BrokerRuntimeReadAuthorization] = []
        for (credential, decision) in [("once", BrokerApprovalDecision.once), ("timed", .timedAllow(duration: 120))] {
            let operation = request(operationID: credential, credentialID: credential)
            let ticket = try machine.submit(operation)
            _ = try machine.decide(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
            authorizations.append(try XCTUnwrap(machine.consumeForRuntime([
                .init(requestID: ticket.requestID, capability: ticket.capability, operationRequest: operation)
            ])))
        }
        defer { authorizations.forEach { $0.finish() } }
        try authorizations[1].registerCleanup {
            XCTAssertFalse(gate.isInside, "Cleanup must run after the spawn gate is released")
            callbacks.record(count: 1)
        }
        machine.setTimedAllowanceRevokedHandler { _ in
            XCTAssertFalse(gate.isInside)
            callbacks.record(count: 2)
        }
        machine.configureOperationStateChanged { _, _, _, _ in
            XCTAssertFalse(gate.isInside)
            callbacks.record(count: 3)
        }
        machine.configureTimedAllowanceScreenState { [weak machine] in
            if let machine {
                machine.lock.lock()
                machine.timedAllowanceSessionRevision = UUID()
                machine.lock.unlock()
            }
            return true
        }
        let revision = machine.stateRevision
        let generation = machine.timedAllowanceSessionGeneration
        var deliveryLeases: [BrokerTextDeliveryLease] = []
        defer { deliveryLeases.forEach { $0.cleanup() } }
        for (kind, runtime) in [("once", authorizations[0]), ("timed", authorizations[1])] {
            let lease = BrokerTextDeliveryLease(beginSpawnAuthorization: { gate.enter() }, validate: {},
                endSpawnAuthorization: { gate.leave() }, spawnDeadline: nil, runtimeAuthorization: runtime, finish: {})
            deliveryLeases.append(lease)
            if kind == "timed" {
                XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {
                    XCTFail("Unvalidated timed authority must not spawn")
                }))
            } else {
                XCTAssertEqual(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { "spawned" }), "spawned")
            }
            lease.finish()
            XCTAssertFalse(gate.isInside)
            XCTAssertTrue(callbacks.counts.isEmpty)
        }
        gate.enter()
        XCTAssertNoThrow(try authorizations[0].validate())
        XCTAssertThrowsError(try authorizations[1].validate())
        gate.leave()
        XCTAssertEqual(machine.stateRevision, revision, "Runtime checks must not run mutate inside the gate")
        XCTAssertEqual(machine.timedAllowanceSessionGeneration, generation)
        XCTAssertTrue(callbacks.counts.isEmpty)
        XCTAssertNil(machine.timedAllowanceScreenSample)
        XCTAssertFalse(machine.timedAllowanceScreenSampleFailed)
        machine.configureTimedAllowanceScreenState { false }
        XCTAssertEqual(callbacks.counts, [1, 2])
        machine.configureTimedAllowanceScreenState { true }
        XCTAssertThrowsError(try authorizations[1].validate(), "Global revocation must never be undone")
        XCTAssertNoThrow(try authorizations[0].validate())
    }
}

private final class RuntimeGateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = false
    var isInside: Bool { lock.lock(); defer { lock.unlock() }; return inside }
    func enter() { lock.lock(); inside = true; lock.unlock() }
    func leave() { lock.lock(); inside = false; lock.unlock() }
}
