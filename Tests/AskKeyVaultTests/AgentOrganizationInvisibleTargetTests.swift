import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentOrganizationInvisibleTargetTests: AgentOrganizationTestSupport {
    private func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    func testInvisibleAndAbsentTargetsHaveIdenticalAgentOutcomesForCreateAndRename() throws {
        for operation: BrokerOrganizationOperation in [.createGroup("target"), .renameGroup(from: "Source", to: "target")] {
            var observable: [Data] = []
            for state in ["hidden", "recycled", "stored-invisible", "absent"] {
                let harness = try makeHarness { _ in true }
                try credential("Source Member", group: "Source", harness: harness)
                if state != "absent" {
                    let member = try credential("Invisible", group: "Target",
                        permission: state == "recycled" ? .ask : .hidden, harness: harness)
                    if state == "recycled" { try harness.vault.deleteTextCredential(id: member.id, using: .allow) }
                    if state == "stored-invisible" { try harness.vault.createCredentialGroup("Target", using: .allow) }
                }
                XCTAssertEqual(try harness.vault.brokerCredentialGroups(), ["Source"])
                let batch = request([operation], id: "identical-batch")
                let ticket = try submitted(harness.vault.requestAgentTextWrite(batch))
                XCTAssertFalse(ticket.requestID.isEmpty)
                XCTAssertFalse(ticket.capability.isEmpty)
                let normalized = AgentTextWriteSubmission(operationID: ticket.operationID, requestID: "random-request-id",
                    capability: "random-capability", state: ticket.state, retryCount: ticket.retryCount)
                observable.append(try canonical(normalized))
                let retransmission = try submitted(harness.vault.requestAgentTextWrite(batch))
                XCTAssertEqual(retransmission.requestID, ticket.requestID)
                XCTAssertEqual(retransmission.capability, ticket.capability)
                XCTAssertEqual(retransmission.retryCount, 1)
                XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
                XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket)) {
                    XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
                }
                XCTAssertEqual(try harness.vault.cancelAgentTextWrite(operationID: batch.operationID,
                    requestID: ticket.requestID, capability: ticket.capability), .cancelled)
            }
            XCTAssertEqual(Set(observable).count, 1)
        }
    }

    func testInvisibleCreationIsNoOpAndRenameMergesUsingExistingSpelling() throws {
        for stored in [false, true] {
            let harness = try makeHarness { _ in true }
            let source = try credential("Source", group: "Old", harness: harness)
            let hidden = try credential("Hidden", group: "Café", permission: .hidden, harness: harness)
            let recycled = try credential("Recycled", group: "Café", harness: harness)
            try harness.vault.deleteTextCredential(id: recycled.id, using: .allow)
            if stored { try harness.vault.createCredentialGroup("Café", using: .allow) }
            let before = try canonical(harness.store.fetchAllCredentialsIncludingRecycled().sorted { $0.id < $1.id })
            let configBefore = try harness.store.configValue(key: Vault.credentialGroupsConfigKey)
            let creation = request([.createGroup("  CAFE\u{301}  ")])
            let createTicket = try approve(creation, harness: harness)
            XCTAssertEqual(try harness.vault.frozenAgentOrganizationSummary(operationID: creation.operationID,
                requestID: createTicket.requestID, capability: createTicket.capability).operations,
                [.existingGroup(name: "Café", members: 2, nonvisible: 2)])
            _ = try commit(creation, harness: harness, ticket: createTicket)
            XCTAssertEqual(try canonical(harness.store.fetchAllCredentialsIncludingRecycled().sorted { $0.id < $1.id }), before)
            XCTAssertEqual(try harness.store.configValue(key: Vault.credentialGroupsConfigKey), configBefore)
            let rename = request([.renameGroup(from: "Old", to: "CAFE\u{301}")])
            let renameTicket = try approve(rename, harness: harness)
            XCTAssertEqual(try harness.vault.frozenAgentOrganizationSummary(operationID: rename.operationID,
                requestID: renameTicket.requestID, capability: renameTicket.capability).operations,
                [.mergeGroup(from: "Old", to: "Café", members: 1, nonvisible: 0, targetMembers: 2, targetNonvisible: 2)])
            _ = try commit(rename, harness: harness, ticket: renameTicket)
            for id in [source.id, hidden.id, recycled.id] { XCTAssertEqual(try group(id, harness: harness), "Café") }
            XCTAssertEqual(try harness.vault.listCredentialGroups(), ["Café"])
            XCTAssertEqual(try harness.vault.brokerCredentialGroups(), ["Café"])
        }
    }

    func testAnyInvisibleTargetStateChangeInvalidatesCreationAndMerge() throws {
        for operation: BrokerOrganizationOperation in [.createGroup("Target"), .renameGroup(from: "Old", to: "Target")] {
            for change in ["permission", "notes", "membership", "stored-name"] {
                let harness = try makeHarness { _ in true }
                let source = try credential("Source", group: "Old", harness: harness)
                let target = try credential("Target Member", group: "Target", permission: .hidden, harness: harness)
                let batch = request([operation])
                let ticket = try approve(batch, harness: harness)
                if change == "membership" { try credential("Joined", group: "Target", permission: .hidden, harness: harness) }
                else if change == "stored-name" { try harness.vault.createCredentialGroup("Target", using: .allow) }
                else {
                    var record = try XCTUnwrap(harness.store.fetchCredential(id: target.id))
                    if change == "permission" { record.permission = CredentialPermission.ask.rawValue }
                    else { record.encryptedPrivateNotes = try VaultCrypto.encrypt("synthetic-changed", using: harness.key) }
                    try harness.store.updateCredential(record)
                }
                XCTAssertThrowsError(try commit(batch, harness: harness, ticket: ticket)) {
                    guard case VaultError.credentialChanged = $0 else { return XCTFail("Expected stale hidden state, got \($0)") }
                }
                XCTAssertEqual(try group(source.id, harness: harness), "Old")
                XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: batch.operationID))
            }
        }
    }
}
