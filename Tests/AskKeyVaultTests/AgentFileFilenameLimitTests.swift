import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentFileFilenameLimitTests: HumanFileCredentialTestSupport {
    func testAgentCreateAndModifyApplyVaultFilenameLimitBeforeWriting() throws {
        for operation in [BrokerApprovalOperation.create, .modify] {
            for length in [255, 256, 4096] {
                let harness = try makeManagedHarness()
                let existing = try harness.vault.createFileCredential(.init(name: "Existing",
                    snapshot: try .init(originalFilename: "synthetic.pem", bytes: Data("synthetic-old".utf8))), using: .allow)
                let bytes = Data("synthetic-new".utf8)
                let id = operation == .create ? UUID().uuidString : existing.id
                let target = operation == .create ? "New file" : existing.id
                let file = BrokerFrozenFile(operationID: UUID().uuidString, credentialID: id, targetID: target,
                    operation: operation, previousDigest: operation == .modify ? existing.contentDigest : nil,
                    originalFilename: String(repeating: "F", count: length), bytes: bytes, byteCount: bytes.count,
                    digest: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
                let ticket = try harness.vault.approvalRequests.submit(.init(operationID: file.operationID,
                    credentialID: id, targetID: target, operation: operation, payloadDigest: file.approvalPayloadDigest),
                    trustedCredentialDeadline: .none)
                _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
                let approved = BrokerFrozenFile(operationID: file.operationID, credentialID: id, targetID: target,
                    operation: operation, previousDigest: file.previousDigest, originalFilename: file.originalFilename,
                    bytes: bytes, byteCount: bytes.count, digest: file.digest,
                    approvalRequestID: ticket.requestID, approvalCapability: ticket.capability)
                if length == 255 {
                    XCTAssertNoThrow(try harness.vault.commitAgentFileWrite(approved))
                    XCTAssertEqual(try harness.vault.revealTextCredential(id: id, using: .allow).originalFilename?.utf8.count, 255)
                } else {
                    XCTAssertThrowsError(try harness.vault.commitAgentFileWrite(approved))
                    XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: file.operationID))
                    XCTAssertEqual(try harness.vault.revealTextCredential(id: existing.id, using: .allow).fileBytes, Data("synthetic-old".utf8))
                    if operation == .create { XCTAssertNil(try harness.store.fetchCredential(id: id)) }
                }
            }
        }
    }
}
