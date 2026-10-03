import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentTextWriteApprovalLifecycleTests: AgentTextWriteTestSupport {
    func testExpiredAndDisconnectedWritesCannotCommit() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 10_000))
        let machine = BrokerApprovalStateMachine(
            requestTTL: 60,
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let harness = try makeHarness(
            now: { clock.now },
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        let expiredRequest = AgentTextWriteRequest(
            operationID: "expired",
            action: .create(name: "Expired", value: "expired-value")
        )
        let expired = try submitted(harness.vault.requestAgentTextWrite(expiredRequest))
        clock.now.addTimeInterval(60)
        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                expiredRequest,
                requestID: expired.requestID,
                capability: expired.capability
            )
        )

        let disconnectedRequest = AgentTextWriteRequest(
            operationID: "disconnected",
            action: .create(name: "Disconnected", value: "disconnect-value")
        )
        let disconnected = try submitted(harness.vault.requestAgentTextWrite(disconnectedRequest))
        XCTAssertEqual(
            try harness.vault.cancelAgentTextWrite(
                operationID: disconnectedRequest.operationID,
                requestID: disconnected.requestID,
                capability: disconnected.capability
            ),
            .cancelled
        )
        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                disconnectedRequest,
                requestID: disconnected.requestID,
                capability: disconnected.capability
            )
        )
        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
    }
    func testCredentialExpiryAfterFreezeCancelsEveryPendingWriteAndPreservesValue() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 40_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let harness = try makeHarness(
            now: { clock.now },
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        let existing = try harness.vault.createTextCredential(
            .init(
                name: "Expiring Target",
                value: "original-value",
                permission: .ask,
                expiresAt: clock.now.addingTimeInterval(10)
            ),
            using: .allow
        )
        let modify = AgentTextWriteRequest(
            operationID: "expiring-modify",
            action: .modify(name: "Expiring Target", value: "new-value")
        )
        let delete = AgentTextWriteRequest(
            operationID: "expiring-delete",
            action: .delete(name: "Expiring Target")
        )
        let modifyTicket = try submitted(harness.vault.requestAgentTextWrite(modify))
        let deleteTicket = try submitted(harness.vault.requestAgentTextWrite(delete))
        _ = try machine.decide(
            requestID: modifyTicket.requestID,
            capability: modifyTicket.capability,
            decision: .once
        )

        clock.now.addTimeInterval(10)
        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                modify,
                requestID: modifyTicket.requestID,
                capability: modifyTicket.capability
            )
        ) { error in
            guard case VaultError.credentialUnavailable = error else {
                return XCTFail("Expected credentialUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(
            try machine.status(requestID: modifyTicket.requestID, capability: modifyTicket.capability),
            .cancelled
        )
        XCTAssertEqual(
            try machine.status(requestID: deleteTicket.requestID, capability: deleteTicket.capability),
            .cancelled
        )
        XCTAssertEqual(
            try harness.vault.revealTextCredential(id: existing.id, using: .allow).value,
            "original-value"
        )
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [existing.id])
    }
    func testWriteTransactionReadsTrustedClockAfterItStarts() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 50_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let harness = try makeHarness(
            now: { clock.now },
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        let existing = try harness.vault.createTextCredential(
            .init(
                name: "Queued Expiry",
                value: "original-value",
                permission: .ask,
                expiresAt: clock.now.addingTimeInterval(10)
            ),
            using: .allow
        )
        let request = AgentTextWriteRequest(
            operationID: "queued-expiry-modify",
            action: .modify(name: "Queued Expiry", value: "new-value")
        )
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        let frozen = try XCTUnwrap(harness.vault.agentTextWrites.entry(operationID: request.operationID))
        clock.now.addTimeInterval(10)

        XCTAssertThrowsError(try harness.store.commitAgentTextWrite(
            frozen,
            requestID: ticket.requestID,
            capabilityDigest: String(repeating: "a", count: 64),
            clock: { clock.now }
        )) { error in
            guard case VaultError.credentialUnavailable = error else {
                return XCTFail("Expected credentialUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(
            try harness.vault.revealTextCredential(id: existing.id, using: .allow).value,
            "original-value"
        )
    }
    func testRealExpiryTimerClearsFrozenWritesBeforeCommit() throws {
        let machine = BrokerApprovalStateMachine(authenticate: { _ in true })
        let harness = try makeHarness(
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        let now = Date()
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 2)
        let existing = try harness.vault.createTextCredential(
            .init(
                name: "Timer Expiry",
                value: "original-value",
                permission: .ask,
                expiresAt: expiry
            ),
            using: .allow
        )
        let modify = AgentTextWriteRequest(
            operationID: "timer-expiry-modify",
            action: .modify(name: "Timer Expiry", value: "new-value")
        )
        let delete = AgentTextWriteRequest(
            operationID: "timer-expiry-delete",
            action: .delete(name: "Timer Expiry")
        )
        let modifyTicket = try submitted(harness.vault.requestAgentTextWrite(modify))
        let deleteTicket = try submitted(harness.vault.requestAgentTextWrite(delete))
        _ = try machine.decide(
            requestID: modifyTicket.requestID,
            capability: modifyTicket.capability,
            decision: .once
        )
        let queueEmptied = DispatchSemaphore(value: 0)
        machine.configureObservers(
            notify: { _ in },
            pendingCountChanged: { count in
                if count == 0 { queueEmptied.signal() }
            }
        )

        XCTAssertEqual(queueEmptied.wait(timeout: .now() + 4), .success)
        XCTAssertEqual(
            try machine.status(requestID: modifyTicket.requestID, capability: modifyTicket.capability),
            .expired
        )
        XCTAssertEqual(
            try machine.status(requestID: deleteTicket.requestID, capability: deleteTicket.capability),
            .expired
        )
        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                modify,
                requestID: modifyTicket.requestID,
                capability: modifyTicket.capability
            )
        ) { error in
            if error as? BrokerApprovalError == .requestNotFound { return }
            if case VaultError.credentialUnavailable = error { return }
            XCTFail("Expected an expired write rejection, got \(error)")
        }
        XCTAssertEqual(
            try harness.vault.revealTextCredential(id: existing.id, using: .allow).value,
            "original-value"
        )
    }
    func testExpiredFrozenWritesReleaseCapacityWithoutRestart() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 30_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let harness = try makeHarness(
            now: { clock.now },
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        var expiring: [(AgentTextWriteRequest, AgentTextWriteSubmission)] = []
        for index in 0..<BrokerLimits.maximumPendingApprovalRequests {
            let request = AgentTextWriteRequest(
                operationID: "expiring-\(index)",
                action: .create(name: "Expiring \(index)", value: "value-\(index)")
            )
            expiring.append((request, try submitted(harness.vault.requestAgentTextWrite(request))))
        }

        clock.now.addTimeInterval(5 * 60)
        for (request, original) in expiring {
            let replay = try submitted(harness.vault.requestAgentTextWrite(request))
            XCTAssertEqual(replay.requestID, original.requestID)
            XCTAssertEqual(replay.capability, original.capability)
            XCTAssertEqual(replay.state, .expired)
        }
        let replacement = try submitted(harness.vault.requestAgentTextWrite(.init(
            operationID: "after-expiry",
            action: .create(name: "After Expiry", value: "replacement")
        )))
        XCTAssertEqual(replacement.state, .pending)
    }
    func testCancellationCannotCrossOperationCapabilities() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let firstRequest = AgentTextWriteRequest(
            operationID: "cancel-first",
            action: .create(name: "First", value: "first-value")
        )
        let secondRequest = AgentTextWriteRequest(
            operationID: "cancel-second",
            action: .create(name: "Second", value: "second-value")
        )
        let first = try submitted(harness.vault.requestAgentTextWrite(firstRequest))
        let second = try submitted(harness.vault.requestAgentTextWrite(secondRequest))

        XCTAssertThrowsError(
            try harness.vault.cancelAgentTextWrite(
                operationID: firstRequest.operationID,
                requestID: second.requestID,
                capability: second.capability
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: first.requestID,
                capability: first.capability
            ),
            .pending
        )
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: second.requestID,
                capability: second.capability
            ),
            .pending
        )
    }
}
