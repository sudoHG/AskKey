import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentOrganizationConcurrencyTests: AgentOrganizationTestSupport {
    func testAnyAffectedRecordChangeRollsBackEvenWithUnchangedTimestamp() throws {
        let harness = try makeHarness { _ in true }
        let a = try credential("A", group: "Old", harness: harness)
        let hidden = try credential("Hidden", group: "Old", permission: .hidden, harness: harness)
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New"), .deleteGroup("Old")])
        let ticket = try approve(batch, harness: harness)
        var changed = try XCTUnwrap(harness.store.fetchCredential(id: hidden.id))
        changed.encryptedPrivateNotes = try VaultCrypto.encrypt("synthetic-changed", using: harness.key)
        try harness.store.updateCredential(changed)
        XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket)) { error in
            guard case VaultError.credentialChanged = error else { return XCTFail("Expected stale record, got \(error)") }
        }
        XCTAssertEqual(try group(a.id, harness: harness), "Old")
        XCTAssertEqual(try group(hidden.id, harness: harness), "Old")
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Old"])
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
    }

    func testNewlyHiddenMemberFailsBothMoveAndGroupOnlyBatch() throws {
        for operation: BrokerOrganizationOperation in [.move(credential: "A", group: nil), .deleteGroup("Old")] {
            let harness = try makeHarness { _ in true }
            let a = try credential("A", group: "Old", harness: harness)
            let batch = request([operation])
            let ticket = try approve(batch, harness: harness)
            var changed = try XCTUnwrap(harness.store.fetchCredential(id: a.id))
            changed.permission = CredentialPermission.hidden.rawValue
            try harness.store.updateCredential(changed)
            XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
            XCTAssertEqual(try group(a.id, harness: harness), "Old")
            XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
        }
    }

    func testExplicitMoveExpiryShortensDeadlineAndPreventsCommit() throws {
        let clock = MutableClock(Date())
        let harness = try makeHarness(now: { clock.now }) { _ in true }
        let expiry = clock.now.addingTimeInterval(2)
        let a = try credential("A", expiresAt: expiry, harness: harness)
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New")])
        let ticket = try approve(batch, harness: harness)
        clock.now = expiry.addingTimeInterval(1)
        XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .expired)
        XCTAssertNil(try group(a.id, harness: harness))
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
    }

    func testRenameOnlyMembersCanExpireWithoutShorteningDeadlineOrBlockingCommit() throws {
        let clock = MutableClock(Date())
        let harness = try makeHarness(now: { clock.now }) { _ in true }
        let a = try credential("A", group: "Old", expiresAt: clock.now.addingTimeInterval(2), harness: harness)
        let hidden = try credential("Hidden", group: "Old", permission: .hidden,
            expiresAt: clock.now.addingTimeInterval(-60), harness: harness)
        let batch = request([.renameGroup(from: "Old", to: "New")])
        let ticket = try approve(batch, harness: harness)
        clock.now = clock.now.addingTimeInterval(3)
        _ = try harness.vault.brokerCredentialCatalog(now: clock.now)
        let read = BrokerTextRunRequest(operationID: "expired-read", command: ["/usr/bin/true"], credentialNames: ["A"])
        XCTAssertThrowsError(try harness.vault.brokerTextCredentials(for: read, cancellation: .init()))
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(.init(operationID: "expired-write", action: .modify(name: "A", value: "synthetic"))))
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
        _ = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(try group(a.id, harness: harness), "New")
        XCTAssertEqual(try group(hidden.id, harness: harness), "New")
    }

    func testBrowsingAfterMovedMemberExpiryExpiresWholeBatch() throws {
        let clock = MutableClock(Date())
        let harness = try makeHarness(now: { clock.now }) { _ in true }
        try credential("A", group: "Old", expiresAt: clock.now.addingTimeInterval(2), harness: harness)
        let batch = request([.move(credential: "A", group: nil)])
        let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
        clock.now = clock.now.addingTimeInterval(3)
        _ = try harness.vault.brokerCredentialCatalog(now: clock.now)
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .expired)
        XCTAssertNil(harness.vault.agentOrganizations.entry(operationID: batch.operationID))
        XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
    }

    func testNamedGroupMembershipAndExistenceChangesInvalidateFrozenBatch() throws {
        for changesMembership in [true, false] {
            let harness = try makeHarness { _ in true }
            let a = try credential("A", group: "Old", harness: harness)
            let batch = request([.createGroup("New"), .renameGroup(from: "Old", to: "Renamed")])
            let ticket = try approve(batch, harness: harness)
            if changesMembership { try credential("Joined", group: "Old", permission: .hidden, harness: harness) }
            else { try harness.vault.createCredentialGroup("New", using: .allow) }
            XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket)) { error in
                guard case VaultError.credentialChanged = error else { return XCTFail("Expected changed named group, got \(error)") }
            }
            XCTAssertEqual(try group(a.id, harness: harness), "Old")
            XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
        }
    }

    func testUnrelatedAppGroupEditSurvivesPendingOrganization() throws {
        let harness = try makeHarness { _ in true }
        let a = try credential("A", group: "Old", harness: harness)
        let batch = request([.renameGroup(from: "Old", to: "New")])
        let ticket = try approve(batch, harness: harness)
        try harness.vault.createCredentialGroup("Unrelated", using: .allow)
        _ = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["New", "Unrelated"])
        XCTAssertEqual(try group(a.id, harness: harness), "New")
    }

    func testRetransmissionPayloadCapabilitiesAndReplayBindWholeBatch() throws {
        let harness = try makeHarness { _ in true }
        let a = try credential("A", harness: harness)
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New")], id: "stable")
        let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
        let repeated = try submitted(harness.vault.requestAgentTextWrite(batch))
        XCTAssertEqual(repeated.requestID, ticket.requestID)
        XCTAssertEqual(repeated.retryCount, 1)
        let changed = request([.createGroup("Other"), .move(credential: "A", group: "Other")], id: batch.operationID)
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(changed)) { XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch) }
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        XCTAssertThrowsError(try commit(changed, harness: harness, ticket: ticket)) { XCTAssertEqual($0 as? BrokerApprovalError, .payloadMismatch) }
        XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(batch, requestID: ticket.requestID, capability: "wrong"))
        let result = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(try commit(batch, harness: harness, ticket: ticket), result)
        XCTAssertEqual(try harness.vault.requestAgentTextWrite(batch), .completed(result))
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(changed))
        XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(batch, requestID: ticket.requestID, capability: "wrong"))
        XCTAssertEqual(try group(a.id, harness: harness), "New")
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords().filter { $0.result == .allowed && $0.operation == .modify }.count, 1)
    }

    func testDenialCancellationAndExpiryDiscardFrozenBatchAndKeepTerminalRetransmission() throws {
        for state in [BrokerRequestState.denied, .cancelled, .expired] {
            let clock = MutableClock(Date())
            let harness = try makeHarness(now: { clock.now }) { _ in true }
            let a = try credential("A", group: "Old", harness: harness)
            let batch = request([.deleteGroup("Old")])
            let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
            switch state {
            case .denied: _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .deny)
            case .cancelled: _ = try harness.vault.cancelAgentTextWrite(operationID: batch.operationID, requestID: ticket.requestID, capability: ticket.capability)
            default: clock.now = clock.now.addingTimeInterval(600)
            }
            XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), state)
            XCTAssertNil(harness.vault.agentOrganizations.entry(operationID: batch.operationID))
            XCTAssertEqual(try submitted(harness.vault.requestAgentTextWrite(batch)).state, state)
            XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
            XCTAssertEqual(try group(a.id, harness: harness), "Old")
            try harness.vault.beginManagementSession(using: .allow)
            XCTAssertEqual(try harness.vault.listCredentialAccessRecords().filter { $0.operation == .modify && $0.result == .denied }.map(\.credentialID), [a.id])
        }
    }

    func testRevocationMatchesAnyMemberAndAuthenticationCancellationStaysPending() throws {
        let harness = try makeHarness { _ in false }
        let a = try credential("A", group: "Old", harness: harness)
        let b = try credential("B", group: "Old", harness: harness)
        let batch = request([.deleteGroup("Old")])
        let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
        XCTAssertThrowsError(try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertEqual(harness.vault.approvalRequests.cancelPending(credentialID: b.id), 1)
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
        XCTAssertEqual(try group(a.id, harness: harness), "Old")
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords().filter { $0.result == .denied && $0.operation == .modify }.map(\.credentialID).compactMap { $0 }.sorted(), [a.id, b.id].sorted())
    }
}
