import CryptoKit
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentOrganizationTests: AgentOrganizationTestSupport {
    func testMixedBatchIsFrozenAndCommitsInOrderWithOneApprovalAndAuthentication() throws {
        let purposes = AuthenticationPurposes()
        let harness = try makeHarness { purposes.append($0); return true }
        let a = try credential("A", group: "Old", permission: .allowed, harness: harness)
        let b = try credential("B", group: "Old", harness: harness)
        let before = try XCTUnwrap(harness.store.fetchCredential(id: a.id))
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New"),
            .renameGroup(from: "Old", to: "Renamed"), .move(credential: "B", group: nil), .deleteGroup("Renamed")])
        let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().count, 1)
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertEqual(pending.request.operation, .organize)
        XCTAssertEqual(pending.request.credentialID, "")
        XCTAssertEqual(pending.request.organizationCredentialIDs, [a.id, b.id].sorted())
        let summary = try harness.vault.frozenAgentOrganizationSummary(operationID: batch.operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertEqual(summary.operations, [.createGroup("New"), .move(credential: "A", from: "Old", to: "New"),
            .renameGroup(from: "Old", to: "Renamed", members: 1, nonvisible: 0),
            .move(credential: "B", from: "Renamed", to: nil), .deleteGroup(name: "Renamed", members: 0, nonvisible: 0)])
        XCTAssertEqual(try group(a.id, harness: harness), "Old")
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Old"])
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        _ = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(purposes.values, [.writeApproval])
        XCTAssertEqual(try group(a.id, harness: harness), "New")
        XCTAssertNil(try group(b.id, harness: harness))
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["New"])
        let after = try XCTUnwrap(harness.store.fetchCredential(id: a.id))
        XCTAssertEqual(after.encryptedPayload, before.encryptedPayload)
        XCTAssertEqual(after.encryptedPrivateNotes, before.encryptedPrivateNotes)
        XCTAssertEqual(after.encryptedUsageInstructions, before.encryptedUsageInstructions)
        XCTAssertEqual(after.permission, before.permission)
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords().filter { $0.operation == .modify && $0.result == .allowed }.map(\.credentialID).compactMap { $0 }.sorted(), [a.id, b.id].sorted())
    }

    func testInvalidLaterOperationRejectsWholeBatchBeforeFreezing() throws {
        let harness = try makeHarness { _ in true }
        let a = try credential("A", group: "Original", harness: harness)
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New"), .deleteGroup("Unknown")])
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(batch)) { error in
            guard case VaultError.credentialUnavailable = error else { return XCTFail("Expected generic unavailable, got \(error)") }
        }
        XCTAssertEqual(try group(a.id, harness: harness), "Original")
        XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Original"])
        XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
        XCTAssertNil(harness.vault.agentOrganizations.entry(operationID: batch.operationID))
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
    }

    func testCatalogIncludesEmptyAndVisibleGroupsAndExcludesHiddenOnlyAndRecycledOnly() throws {
        let harness = try makeHarness { _ in true }
        try harness.vault.createCredentialGroup("Empty", using: .allow)
        try credential("Visible", group: "Mixed", harness: harness)
        try credential("Hidden Mixed", group: "Mixed", permission: .hidden, harness: harness)
        try credential("Hidden", group: "Hidden Only", permission: .hidden, harness: harness)
        let recycled = try credential("Recycled", group: "Recycled Only", harness: harness)
        try harness.vault.deleteTextCredential(id: recycled.id, using: .allow)
        XCTAssertEqual(try harness.vault.brokerCredentialGroups(), ["Empty", "Mixed"])
        XCTAssertEqual(try harness.vault.brokerCredentialCatalog().map(\.name), ["Visible"])
        for action: BrokerOrganizationOperation in [.deleteGroup("Hidden Only"), .renameGroup(from: "Hidden Only", to: "Other"),
            .deleteGroup("Recycled Only"), .move(credential: "Visible", group: "Hidden Only"), .move(credential: "Hidden", group: nil), .deleteGroup("Unknown")] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request([action]))) { error in
                guard case VaultError.credentialUnavailable = error else { return XCTFail("Expected generic unavailable, got \(error)") }
            }
        }
    }

    func testRenameAndDeleteIncludeHiddenAndRecycledMembersAndDeleteNoCredentials() throws {
        let harness = try makeHarness { _ in true }
        let visible = try credential("Visible", group: "Old", harness: harness)
        let hidden = try credential("Hidden", group: "Old", permission: .hidden, expiresAt: Date().addingTimeInterval(-60), harness: harness)
        let recycled = try credential("Recycled", group: "Old", harness: harness)
        try harness.vault.deleteTextCredential(id: recycled.id, using: .allow)
        for operation: BrokerOrganizationOperation in [.renameGroup(from: "Old", to: "New"), .deleteGroup("New")] {
            let batch = request([operation])
            let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
            let summary = try harness.vault.frozenAgentOrganizationSummary(operationID: batch.operationID,
                requestID: ticket.requestID, capability: ticket.capability)
            if case .renameGroup = operation {
                XCTAssertEqual(summary.operations, [.renameGroup(from: "Old", to: "New", members: 3, nonvisible: 2)])
            } else { XCTAssertEqual(summary.operations, [.deleteGroup(name: "New", members: 3, nonvisible: 2)]) }
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
            _ = try commit(batch, harness: harness, ticket: ticket)
            for id in [visible.id, hidden.id, recycled.id] {
                XCTAssertEqual(try group(id, harness: harness), operation == .deleteGroup("New") ? nil : "New")
            }
            let records = try harness.store.fetchAllCredentialsIncludingRecycled()
            XCTAssertEqual(records.count, 3)
            XCTAssertEqual(records.first { $0.id == hidden.id }?.permission, CredentialPermission.hidden.rawValue)
            XCTAssertNotNil(records.first { $0.id == recycled.id }?.deletedAt)
        }
    }

    func testVisibleOccupiedRenameAndDuplicateCreationRejectWithGenericError() throws {
        let harness = try makeHarness { _ in true }
        try credential("Visible", group: "Source", harness: harness)
        try credential("Visible Target", group: "Occupied", harness: harness)
        try harness.vault.createCredentialGroup("Empty", using: .allow)
        for operation: BrokerOrganizationOperation in [.renameGroup(from: "Source", to: "OCCUPIED"), .createGroup("occupied"),
            .createGroup("empty"), .renameGroup(from: "Source", to: "EMPTY")] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request([operation]))) { error in
                guard case VaultError.credentialUnavailable = error else { return XCTFail("Expected generic unavailable, got \(error)") }
            }
        }
        let batch = request([.renameGroup(from: "source", to: "  Destination  ")])
        _ = try commit(batch, harness: harness, ticket: approve(batch, harness: harness))
        XCTAssertEqual(try harness.vault.brokerCredentialGroups(), ["Destination", "Empty", "Occupied"])
    }

    func testAllowAndTimedReadAllowanceNeverSkipOrganizationApproval() throws {
        let purposes = AuthenticationPurposes()
        let harness = try makeHarness { purposes.append($0); return true }
        let a = try credential("A", permission: .allowed, harness: harness)
        let read = BrokerApprovalOperationRequest(operationID: "read", credentialID: a.id, targetID: a.id,
            operation: .read, payloadDigest: String(repeating: "a", count: 64))
        let readTicket = try harness.vault.approvalRequests.submit(read, trustedCredentialDeadline: .none)
        _ = try harness.vault.approvalRequests.decide(requestID: readTicket.requestID, capability: readTicket.capability,
            decision: .timedAllow(duration: 600))
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New")])
        let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
        XCTAssertEqual(ticket.state, .pending)
        XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
        XCTAssertThrowsError(try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability,
            decision: .timedAllow(duration: 600)))
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        _ = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(purposes.values.filter { $0 == .writeApproval }.count, 1)
    }

    func testStorageFailureRollsBackRecordsGroupsAndReceiptWithoutBurningApproval() throws {
        let harness = try makeHarness { _ in true }
        let a = try credential("A", harness: harness)
        let batch = request([.createGroup("New"), .move(credential: "A", group: "New")])
        let ticket = try approve(batch, harness: harness)
        try harness.store.db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_organization_receipt BEFORE INSERT ON agent_write_operations BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        }
        XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket))
        XCTAssertNil(try group(a.id, harness: harness))
        XCTAssertTrue(try harness.vault.listCredentialGroups().isEmpty)
        XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
        try harness.store.db.write { try $0.execute(sql: "DROP TRIGGER reject_organization_receipt") }
        _ = try commit(batch, harness: harness, ticket: ticket)
        XCTAssertEqual(try group(a.id, harness: harness), "New")
    }

    func testOperationLimitAndInvalidNamesAreRejectedBeforeApproval() throws {
        let harness = try makeHarness { _ in true }
        for operations in [[], (0..<65).map { BrokerOrganizationOperation.createGroup("Group \($0)") }, [.createGroup("bad\nname")]] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request(operations)))
        }
        let batch = request((0..<64).map { .createGroup("Group \($0)") })
        _ = try commit(batch, harness: harness, ticket: approve(batch, harness: harness))
        XCTAssertEqual(try harness.vault.brokerCredentialGroups().count, 64)
        XCTAssertEqual(try harness.vault.listCredentialAccessRecords().filter { $0.operation == .modify && $0.result == .allowed }.count, 1)
        XCTAssertNil(try harness.vault.listCredentialAccessRecords().first { $0.operation == .modify && $0.result == .allowed }?.credentialID)
    }

    func testMovesAcceptFileCredentialsAndPreserveEveryMaterialAndPolicyField() throws {
        let harness = try makeHarness { _ in true }
        let file = try harness.vault.createFileCredential(.init(name: "SSH File",
            snapshot: try .init(originalFilename: "synthetic.pem", bytes: Data("synthetic-file".utf8)),
            privateNotes: "synthetic-private", groupName: "Old", environmentVariable: "KEY_FILE", permission: .allowed), using: .allow)
        let before = try XCTUnwrap(harness.store.fetchCredential(id: file.id))
        let batch = request([.createGroup("New"), .move(credential: "SSH File", group: "New")])
        _ = try commit(batch, harness: harness, ticket: approve(batch, harness: harness))
        let after = try XCTUnwrap(harness.store.fetchCredential(id: file.id))
        XCTAssertEqual(after.encryptedPayload, before.encryptedPayload)
        XCTAssertEqual(after.encryptedOriginalFilename, before.encryptedOriginalFilename)
        XCTAssertEqual(after.encryptedEnvironmentVariable, before.encryptedEnvironmentVariable)
        XCTAssertEqual(after.encryptedPrivateNotes, before.encryptedPrivateNotes)
        XCTAssertEqual(after.encryptedUsageInstructions, before.encryptedUsageInstructions)
        XCTAssertEqual(after.byteSize, before.byteSize)
        XCTAssertEqual(after.contentDigest, before.contentDigest)
        XCTAssertEqual(after.payloadKind, before.payloadKind)
        XCTAssertEqual(after.permission, before.permission)
        XCTAssertEqual(after.expiresAt, before.expiresAt)
        XCTAssertEqual(try group(file.id, harness: harness), "New")
    }

    func testExpiredMovesAndMissingDestinationsCannotFreezeAndGroupMatchingReusesSpelling() throws {
        let harness = try makeHarness { _ in true }
        try credential("Expired", expiresAt: Date().addingTimeInterval(-60), harness: harness)
        let a = try credential("A", group: "Café", harness: harness)
        for operation: BrokerOrganizationOperation in [.move(credential: "Expired", group: nil), .move(credential: "A", group: "Unknown")] {
            XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request([operation]))) { error in
                guard case VaultError.credentialUnavailable = error else { return XCTFail("Expected generic unavailable") }
            }
        }
        let batch = request([.move(credential: "A", group: "  CAFE\u{301}  ")])
        _ = try commit(batch, harness: harness, ticket: approve(batch, harness: harness))
        XCTAssertEqual(try group(a.id, harness: harness), "Café")
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().count, 0)
    }
}
