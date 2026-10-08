import XCTest
import GRDB
import AskKeyBroker
@testable import AskKeyVault

final class AgentOrganizationCommitBoundaryTests: AgentOrganizationTestSupport {
    func testSingleWriteExpiryRejectionPreservesRenameAndDeleteOnlyApprovalsAtBothChecks() throws {
        for transactionExpiry in [false, true] {
            for deleting in [false, true] {
                let start = Date(timeIntervalSince1970: 2_000_000_000)
                let clock = MutableClock(start)
                let harness = try makeHarness(now: { clock.now }) { _ in true }
                let member = try credential("Member", group: "Old", expiresAt: start.addingTimeInterval(2), harness: harness)
                let single = AgentTextWriteRequest(operationID: "single", action: .modify(name: "Member", value: "synthetic-updated"))
                let singleTicket = try approve(single, harness: harness)
                let batch = request([deleting ? .deleteGroup("Old") : .renameGroup(from: "Old", to: "New")])
                let batchTicket = try approve(batch, harness: harness)
                if transactionExpiry {
                    try harness.store.db.write { db in
                        db.trace { event in
                            if case .statement(let statement) = event, statement.sql.hasPrefix("BEGIN") {
                                clock.now = start.addingTimeInterval(3)
                            }
                        }
                    }
                } else { clock.now = start.addingTimeInterval(3) }
                XCTAssertThrowsError(try commit(single, harness: harness, ticket: singleTicket)) {
                    guard case VaultError.credentialUnavailable = $0 else { return XCTFail("Expected expiry rejection, got \($0)") }
                }
                try harness.store.db.write { $0.trace(nil) }
                XCTAssertEqual(clock.now, start.addingTimeInterval(3))
                XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: single.operationID))
                XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: batchTicket.requestID,
                    capability: batchTicket.capability), .approved)
                _ = try commit(batch, harness: harness, ticket: batchTicket)
                XCTAssertEqual(try group(member.id, harness: harness), deleting ? nil : "New")
            }
        }
    }

    func testCancellationDuringReservedOrganizationTransactionCannotCancelOrRecordDenial() throws {
        let harness = try makeHarness { _ in true }
        let member = try credential("Member", group: "Old", harness: harness)
        let batch = request([.renameGroup(from: "Old", to: "New")])
        let ticket = try approve(batch, harness: harness)
        let transactionEntered = DispatchSemaphore(value: 0)
        let releaseTransaction = DispatchSemaphore(value: 0)
        let commitFinished = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let cancelFinished = DispatchSemaphore(value: 0)
        let commits = ConcurrentResults<AgentTextWriteResult>()
        let cancels = ConcurrentResults<BrokerRequestState>()
        try harness.store.db.write { db in
            db.add(function: DatabaseFunction("block_receipt", argumentCount: 0) { _ in
                transactionEntered.signal()
                _ = releaseTransaction.wait(timeout: .now() + 5)
                return 1
            })
            try db.execute(sql: "CREATE TEMP TRIGGER block_commit BEFORE INSERT ON agent_write_operations BEGIN SELECT block_receipt(); END")
        }
        defer { releaseTransaction.signal() }
        let frozen = try XCTUnwrap(harness.vault.agentOrganizations.entry(operationID: batch.operationID))
        DispatchQueue.global().async {
            commits.append(Result { try harness.vault.commitAgentTextWrite(batch, requestID: ticket.requestID, capability: ticket.capability) })
            commitFinished.signal()
        }
        XCTAssertEqual(transactionEntered.wait(timeout: .now() + 2), .success)
        // The operation-bound overload must independently honor the reservation.
        XCTAssertEqual(try harness.vault.approvalRequests.cancel(requestID: ticket.requestID,
            capability: ticket.capability, operationRequest: frozen.approvalRequest), .approved)
        DispatchQueue.global().async {
            cancelStarted.signal()
            cancels.append(Result { try harness.vault.cancelAgentTextWrite(operationID: batch.operationID,
                requestID: ticket.requestID, capability: ticket.capability) })
            cancelFinished.signal()
        }
        XCTAssertEqual(cancelStarted.wait(timeout: .now() + 2), .success)
        let cancellationBlocked = cancelFinished.wait(timeout: .now() + 0.1)
        releaseTransaction.signal()
        XCTAssertEqual(cancellationBlocked, .timedOut)
        XCTAssertEqual(commitFinished.wait(timeout: .now() + 5), .success)
        if cancellationBlocked == .timedOut { XCTAssertEqual(cancelFinished.wait(timeout: .now() + 5), .success) }
        XCTAssertEqual(commits.values.count, 1)
        _ = try commits.values.first?.get()
        XCTAssertEqual(cancels.values.count, 1)
        switch try XCTUnwrap(cancels.values.first) {
        case .success(let state): XCTAssertNotEqual(state, .cancelled)
        case .failure(let error): XCTAssertEqual(error as? BrokerApprovalError, .requestNotFound)
        }
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .consumed)
        XCTAssertEqual(try group(member.id, harness: harness), "New")
        XCTAssertNotNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
        let records = try harness.vault.listCredentialAccessRecords().filter { $0.credentialID == member.id && $0.operation == .modify }
        XCTAssertEqual(records.map(\.result), [.allowed])
    }
}
