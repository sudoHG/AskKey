import CryptoKit
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentWriteStoredStateBindingTests: AgentTextWriteTestSupport {
    func testEveryStoredFieldChangeRejectsCommitAndRevealEvenWithTheSameTimestamp() throws {
        let changes: [(String, (inout CredentialRecord) -> Void)] = [
            ("id", { $0.id = UUID().uuidString }),
            ("nameIndex", { $0.nameIndex = Data("synthetic-other-index".utf8) }),
            ("displayName", { $0.encryptedDisplayName.append(1) }),
            ("payload", { $0.encryptedPayload.append(1) }),
            ("instructions", { $0.encryptedUsageInstructions.append(1) }),
            ("notes", { $0.encryptedPrivateNotes.append(1) }),
            ("group", { $0.encryptedGroupName = Data("synthetic-other-group".utf8) }),
            ("environment", { $0.encryptedEnvironmentVariable = Data("synthetic-other-mapping".utf8) }),
            ("kind", { $0.payloadKind = CredentialPayloadKind.file.rawValue }),
            ("permission", { $0.permission = CredentialPermission.allowed.rawValue }),
            ("expiry", { $0.expiresAt = "2099-01-01T00:00:00.000Z" }),
            ("createdAt", { $0.createdAt = "2020-01-01T00:00:00.000Z" }),
            ("updatedAt", { $0.updatedAt = "2020-01-01T00:00:00.000Z" }),
            ("filename", { $0.encryptedOriginalFilename = Data("synthetic-other-filename".utf8) }),
            ("size", { $0.byteSize = 42 }),
            ("contentDigest", { $0.contentDigest = Data(repeating: 42, count: 32) }),
            ("deletedAt", { $0.deletedAt = "2020-01-01T00:00:00.000Z" }),
            ("metadata", { $0.encryptedComponentMetadata?.append(1) }),
            ("authenticationTag", { $0.authenticationTag?.append(1) })
        ]
        for operation in [BrokerApprovalOperation.modify, .delete] {
            for (field, change) in changes {
                let harness = try makeHarness { _ in true }
                let created = try harness.vault.createBundleCredential(.init(name: "Synthetic", components: [
                    .init(name: "TOKEN", value: .text("synthetic-old"), delivery: .none)
                ]), using: .allow)
                let request = AgentTextWriteRequest(operationID: "stale-\(field)-\(operation.rawValue)", action: operation == .delete
                    ? .delete(name: created.name)
                    : .modifyBundle(name: created.name, changes: [.upsert(.init(name: "TOKEN", value: .text("synthetic-new"), delivery: .none))]))
                let ticket = try submitted(harness.vault.requestAgentTextWrite(request))
                _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
                let original = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
                var row = original
                change(&row)
                if field != "updatedAt" { XCTAssertEqual(row.updatedAt, original.updatedAt) }
                // Re-seal a legitimate changed row, so row authentication alone
                // cannot stand in for binding approval to the frozen state.
                try harness.store.db.write { db in
                    try original.delete(db)
                    let changed = try field == "authenticationTag" ? row : harness.store.credentialForPersistence(row)
                    try changed.insert(db)
                }
                XCTAssertThrowsError(try harness.vault.revealFrozenCredentialWrite(operationID: request.operationID,
                    requestID: ticket.requestID, capability: ticket.capability, using: .allow), field) {
                    if field == "authenticationTag" {
                        return XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication)
                    }
                    guard case VaultError.credentialChanged = $0 else { return XCTFail("\(field): \($0)") }
                }
                XCTAssertThrowsError(try harness.vault.commitAgentTextWrite(request,
                    requestID: ticket.requestID, capability: ticket.capability), field) {
                    if field == "authenticationTag" {
                        return XCTAssertEqual($0 as? CredentialRecordAuthenticationError, .invalidAuthentication)
                    }
                    // Moving the identity also makes the original name belong
                    // to a different row, preserving the existing conflict gate.
                    if field == "id", operation == .modify, case VaultError.agentWriteNameUnavailable = $0 { return }
                    guard case VaultError.credentialChanged = $0 else { return XCTFail("\(field): \($0)") }
                }
                XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: request.operationID))
            }
        }
    }

    func testCiphertextChangeAltersApprovalDigestWithoutChangingPlaintext() throws {
        let harness = try makeHarness { _ in true }
        let created = try harness.vault.createTextCredential(.init(name: "Synthetic", value: "synthetic-value"), using: .allow)
        let action = AgentTextWriteAction.delete(name: created.name)
        let first = AgentTextWriteRequest(operationID: "first", action: action)
        _ = try harness.vault.requestAgentTextWrite(first)
        let frozen = try XCTUnwrap(harness.vault.agentTextWrites.entry(operationID: first.operationID))
        var row = try XCTUnwrap(harness.store.fetchCredential(id: created.id))
        row.encryptedPayload = try VaultCrypto.encrypt("synthetic-value", using: harness.key)
        try harness.store.updateCredential(row)
        // Reuse the same request digest to isolate stored-state binding.
        let second = try harness.vault.freezeAgentTextWrite(first, digest: frozen.digest, key: harness.key, files: [:])
        XCTAssertNotEqual(frozen.approvalRequest.payloadDigest, second.approvalRequest.payloadDigest)
        XCTAssertNil(frozen.summary?.beforeDigest)
        XCTAssertNil(second.summary?.beforeDigest)
    }
}
