import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentTextWriteGovernanceTests: XCTestCase {
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

    func testConcurrentRetransmissionsShareRequestAndCommittedResult() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let request = AgentTextWriteRequest(
            operationID: "concurrent-create",
            action: .create(name: "Concurrent Create", value: "one-value")
        )
        let submissions = ConcurrentResults<AgentTextWriteSubmission>()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            submissions.append(Result {
                try submitted(harness.vault.requestAgentTextWrite(request))
            })
        }
        let tickets = try submissions.values.map { try $0.get() }
        XCTAssertEqual(Set(tickets.map(\.requestID)).count, 1)
        XCTAssertEqual(Set(tickets.map(\.capability)).count, 1)
        let ticket = try XCTUnwrap(tickets.first)
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )

        let commits = ConcurrentResults<AgentTextWriteResult>()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            commits.append(Result {
                try harness.vault.commitAgentTextWrite(
                    request,
                    requestID: ticket.requestID,
                    capability: ticket.capability
                )
            })
        }
        let results = try commits.values.map { try $0.get() }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first, results.last)
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(try harness.vault.listTextCredentials().map(\.id), [result.credentialID])
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

    func testBrokerSocketForwardsWriteWithoutEchoingValue() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let socketPath = "/tmp/askkey-write-\(UUID().uuidString.prefix(8)).sock"
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in try harness.vault.requestAgentTextWrite(request) },
            commitTextWrite: { request, requestID, capability in
                try harness.vault.commitAgentTextWrite(
                    request,
                    requestID: requestID,
                    capability: capability
                )
            },
            cancelTextWrite: { operationID, requestID, capability in
                try harness.vault.cancelAgentTextWrite(
                    operationID: operationID,
                    requestID: requestID,
                    capability: capability
                )
            }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        defer { server.stop() }
        let write = AgentTextWriteRequest(
            operationID: "wire-create",
            action: .create(name: "Wire", value: "wire-secret-value")
        )
        let response = try BrokerSocketClient(socketPath: socketPath).send(
            .init(version: 1, method: "credential.write.request", textWrite: write)
        )
        let responseJSON = try encoded(response)
        XCTAssertFalse(responseJSON.contains("wire-secret-value"))
        guard case let .success(.textWriteRequest(.submitted(submission))) = response else {
            return XCTFail("Expected write submission, got \(response)")
        }
        _ = try harness.vault.approvalRequests.decide(
            requestID: submission.requestID,
            capability: submission.capability,
            decision: .once
        )
        let committed = try BrokerSocketClient(socketPath: socketPath).send(
            .init(
                version: 1,
                method: "credential.write.commit",
                requestID: submission.requestID,
                capability: submission.capability,
                textWrite: write
            )
        )
        XCTAssertFalse(try encoded(committed).contains("wire-secret-value"))
        guard case let .success(.textWriteResult(result)) = committed else {
            return XCTFail("Expected completed write, got \(committed)")
        }
        XCTAssertEqual(result.operationID, "wire-create")
        XCTAssertEqual(result.state, .completed)
        let replay = try BrokerSocketClient(socketPath: socketPath).send(
            .init(version: 1, method: "credential.write.request", textWrite: write)
        )
        guard case let .success(.textWriteRequest(.completed(replayed))) = replay else {
            return XCTFail("Expected completed replay, got \(replay)")
        }
        XCTAssertEqual(replayed, result)
        XCTAssertFalse(try encoded(replay).contains("wire-secret-value"))
    }

    private func makeHarness(
        now: @escaping @Sendable () -> Date = { Date() },
        approvalRequests: BrokerApprovalStateMachine? = nil,
        authenticate: @escaping @Sendable (BrokerAuthenticationPurpose) -> Bool
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAgentWrites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("vault.db")
        let machine = approvalRequests ?? BrokerApprovalStateMachine(
            clock: now,
            authenticate: authenticate
        )
        let store = try VaultStore(path: databaseURL.path)
        let key = VaultCrypto.generateKey()
        let vault = Vault(
            store: store,
            key: key,
            now: now,
            approvalRequests: machine
        )
        try vault.beginManagementSession(using: .allow)
        return Harness(vault: vault, store: store, key: key, databaseURL: databaseURL)
    }

    private func encoded<T: Encodable>(_ value: T) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder().encode(value), encoding: .utf8))
    }
}

private struct Harness {
    let vault: Vault
    let store: VaultStore
    let key: SymmetricKey
    let databaseURL: URL

    func databaseBytes() throws -> Data {
        var bytes = Data()
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                bytes.append(try Data(contentsOf: url))
            }
        }
        return bytes
    }
}

private func submitted(_ outcome: AgentTextWriteRequestOutcome) throws -> AgentTextWriteSubmission {
    guard case let .submitted(submission) = outcome else {
        throw BrokerApprovalError.invalidDecision
    }
    return submission
}

private final class AuthenticationPurposes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BrokerAuthenticationPurpose] = []
    var values: [BrokerAuthenticationPurpose] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ value: BrokerAuthenticationPurpose) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    var now: Date {
        get {
            lock.lock()
            let value = storage
            lock.unlock()
            return value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
    init(_ now: Date) { storage = now }
}

private final class ConcurrentResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<Value, Error>] = []
    var values: [Result<Value, Error>] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ result: Result<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        storage.append(result)
    }
}
