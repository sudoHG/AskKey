import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentTextWriteCreationTests: AgentTextWriteTestSupport {
    func testCreateFreezesCallerKnownValueWithoutPersistingOrEchoingIt() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let secret = "caller-known-value-\(UUID().uuidString)"
        let request = AgentTextWriteRequest(
            operationID: "create-1",
            action: .create(name: "Deploy Token", value: secret)
        )

        let first = try submitted(harness.vault.requestAgentTextWrite(request))
        let retry = try submitted(harness.vault.requestAgentTextWrite(request))

        XCTAssertEqual(first.requestID, retry.requestID)
        XCTAssertEqual(first.capability, retry.capability)
        XCTAssertEqual(first.retryCount, 0)
        XCTAssertEqual(retry.retryCount, 1)
        XCTAssertEqual(first.state, .pending)
        XCTAssertFalse(try encoded(first).contains(secret))
        XCTAssertFalse(try harness.databaseBytes().contains(Data(secret.utf8)))

        _ = try harness.vault.approvalRequests.decide(
            requestID: first.requestID,
            capability: first.capability,
            decision: .once
        )
        let committed = try harness.vault.commitAgentTextWrite(
            request,
            requestID: first.requestID,
            capability: first.capability
        )
        XCTAssertEqual(committed.state, .completed)
        XCTAssertFalse(try encoded(committed).contains(secret))
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.permission), [.ask])
        XCTAssertEqual(
            try harness.vault.revealTextCredential(id: committed.credentialID, using: .allow).value,
            secret
        )
        XCTAssertEqual(
            try harness.vault.commitAgentTextWrite(
                request,
                requestID: first.requestID,
                capability: first.capability
            ),
            committed
        )
        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                request,
                requestID: first.requestID,
                capability: "wrong-capability"
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .requestNotFound)
        }
        guard case let .completed(replayed) = try harness.vault.requestAgentTextWrite(request) else {
            return XCTFail("Expected a completed retransmission")
        }
        XCTAssertEqual(replayed, committed)

        let restarted = Vault(
            store: try VaultStore(path: harness.databaseURL.path),
            key: harness.key,
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true })
        )
        guard case let .completed(afterRestart) = try restarted.requestAgentTextWrite(request) else {
            return XCTFail("Expected a completed retransmission after restart")
        }
        XCTAssertEqual(afterRestart, committed)
    }
    func testPayloadSwapCannotReuseApprovalAndModificationCannotChangePermission() throws {
        let authentications = AuthenticationPurposes()
        let harness = try makeHarness(authenticate: {
            authentications.append($0)
            return true
        })
        let existing = try harness.vault.createTextCredential(
            .init(name: "Existing", value: "old", permission: .allowed),
            using: .allow
        )
        let request = AgentTextWriteRequest(
            operationID: "modify-1",
            action: .modify(name: "Existing", value: "new")
        )
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )

        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                .init(operationID: "modify-1", action: .modify(name: "Existing", value: "swapped")),
                requestID: ticket.requestID,
                capability: ticket.capability
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }

        let result = try harness.vault.commitAgentTextWrite(
            request,
            requestID: ticket.requestID,
            capability: ticket.capability
        )
        let revealed = try harness.vault.revealTextCredential(id: result.credentialID, using: .allow)
        XCTAssertEqual(revealed.value, "new")
        XCTAssertEqual(revealed.permission, .allowed)
        XCTAssertEqual(existing.id, result.credentialID)
        XCTAssertEqual(authentications.values, [.writeApproval])
    }
    func testDeleteUsesThirtyDayRecycleBinAndPermanentDeleteIsAppOnly() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = try makeHarness(now: { start }, authenticate: { _ in true })
        let existing = try harness.vault.createTextCredential(
            .init(name: "Disposable", value: "value"),
            using: .allow
        )
        let request = AgentTextWriteRequest(
            operationID: "delete-1",
            action: .delete(name: "Disposable")
        )
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        _ = try harness.vault.commitAgentTextWrite(
            request,
            requestID: ticket.requestID,
            capability: ticket.capability
        )

        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
        XCTAssertEqual(try harness.vault.listRecycledTextCredentials().map(\.id), [existing.id])
        XCTAssertEqual(try harness.vault.purgeRecycledTextCredentials(olderThan: start.addingTimeInterval(30 * 24 * 60 * 60 - 1), using: .allow), 0)
        XCTAssertThrowsError(
            try harness.vault.purgeRecycledTextCredentials(
                olderThan: start.addingTimeInterval(30 * 24 * 60 * 60),
                using: .deny
            )
        )
        try harness.vault.restoreRecycledTextCredential(id: existing.id, using: .allow)
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [existing.id])

        try harness.vault.deleteTextCredential(id: existing.id, using: .allow)
        try harness.vault.permanentlyDeleteRecycledTextCredential(id: existing.id, using: .allow)
        XCTAssertTrue(try harness.vault.listRecycledTextCredentials().isEmpty)
    }
    func testDatabaseFailureRollsBackOperationWithoutBurningApproval() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 20_000))
        let machine = BrokerApprovalStateMachine(
            clock: { clock.now },
            authenticate: { _ in true }
        )
        let harness = try makeHarness(
            now: { clock.now },
            approvalRequests: machine,
            authenticate: { _ in true }
        )
        let request = AgentTextWriteRequest(
            operationID: "faulted-create",
            action: .create(name: "Faulted", value: "agent-value")
        )
        let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
        _ = try machine.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        try harness.store.db.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_agent_create
                BEFORE INSERT ON credentials
                BEGIN SELECT RAISE(ABORT, 'injected failure'); END
            """)
        }

        XCTAssertThrowsError(
            try harness.vault.commitAgentTextWrite(
                request,
                requestID: ticket.requestID,
                capability: ticket.capability
            )
        )
        XCTAssertEqual(
            try machine.status(requestID: ticket.requestID, capability: ticket.capability),
            .approved
        )
        XCTAssertTrue(try harness.vault.listTextCredentials().isEmpty)
        try harness.store.db.write { db in
            try db.execute(sql: "DROP TRIGGER fail_agent_create")
        }
        let committed = try harness.vault.commitAgentTextWrite(
            request,
            requestID: ticket.requestID,
            capability: ticket.capability
        )
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [committed.credentialID])
    }
}
