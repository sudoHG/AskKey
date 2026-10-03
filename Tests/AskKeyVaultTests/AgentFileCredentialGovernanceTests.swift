import CryptoKit
import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentFileCredentialGovernanceTests: HumanFileCredentialTestSupport {
    func testAgentFileCommitAtomicallyRejectsAStalePreviousDigest() throws {
        let harness = try makeManagedHarness()
        func authorize(_ file: BrokerFrozenFile) throws -> BrokerFrozenFile {
            let ticket = try harness.vault.approvalRequests.submit(.init(operationID: file.operationID,
                credentialID: file.credentialID, targetID: file.targetID,
                operation: file.operation, payloadDigest: file.approvalPayloadDigest), trustedCredentialDeadline: .none)
            _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID,
                capability: ticket.capability, decision: .once)
            return .init(operationID: file.operationID, credentialID: file.credentialID,
                targetID: file.targetID, operation: file.operation, previousDigest: file.previousDigest,
                originalFilename: file.originalFilename, bytes: file.bytes, byteCount: file.byteCount,
                digest: file.digest, approvalRequestID: ticket.requestID, approvalCapability: ticket.capability)
        }
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let approved = BrokerFrozenFile(
            operationID: "approved-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            previousDigest: created.contentDigest,
            originalFilename: "AuthKey.p8",
            bytes: replacement,
            byteCount: replacement.count,
            digest: Self.binaryDigestHex
        )
        try harness.vault.commitAgentFileWrite(authorize(approved))

        let staleBytes = Data("stale-replacement".utf8)
        let stale = BrokerFrozenFile(
            operationID: "stale-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            previousDigest: created.contentDigest,
            originalFilename: "stale.p8",
            bytes: staleBytes,
            byteCount: staleBytes.count,
            digest: "02f9b34e708c0f04f4e122a1b9f07060daf3193a79cbe8224f88454daf742dba"
        )
        XCTAssertThrowsError(try harness.vault.commitAgentFileWrite(authorize(stale))) { error in
            guard case VaultError.credentialChanged = error else {
                return XCTFail("expected credentialChanged, got \(error)")
            }
        }
        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, replacement)
        XCTAssertEqual(revealed.contentDigest, Self.binaryDigestHex)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }
    func testCoordinatorPublicCommitUsesVaultConditionalTransaction() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "最终单文件协议",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let staging = harness.directory.appendingPathComponent("agent-write-staging")
        let coordinator = try makeAgentCoordinator(harness, stagingDirectory: staging)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let upload = try coordinator.begin(
            operationID: "integrated-rotation",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            originalFilename: "AuthKey.p8",
            expectedByteCount: replacement.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: replacement
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertEqual(pending.trustedCredentialName, "最终单文件协议")
        XCTAssertEqual(pending.displayCredentialName, "最终单文件协议")
        XCTAssertNil(pending.request.credentialName)
        XCTAssertEqual(pending.request.credentialID, created.id)
        XCTAssertEqual(pending.request.targetID, created.id)
        let retried = try coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        XCTAssertEqual(retried.requestID, approval.requestID)
        XCTAssertEqual(retried.capability, approval.capability)
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().first?.request, pending.request)
        XCTAssertEqual(harness.vault.approvalRequests.pendingRequests().first?.displayCredentialName, "最终单文件协议")
        let summary = try coordinator.summary(requestID: approval.requestID)
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )

        let revealed = try harness.vault.revealTextCredential(id: created.id, using: .allow)
        XCTAssertEqual(revealed.fileBytes, replacement)
        XCTAssertEqual(revealed.contentDigest, Self.binaryDigestHex)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }
    func testFileApprovalDisplayNameIgnoresCallerMetadataWithoutChangingBinding() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("fixture.pem")
        try Data("synthetic-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(name: "可信文件名称", snapshot: try FileImport.freeze(url: source)),
            using: .allow
        )
        let request = BrokerApprovalOperationRequest(
            operationID: "display-metadata",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            payloadDigest: String(repeating: "a", count: 64),
            credentialName: "caller-display-label"
        )
        let mismatchedTarget = BrokerApprovalOperationRequest(
            operationID: request.operationID, credentialID: created.id,
            targetID: "caller-target-label", operation: .modify,
            payloadDigest: request.payloadDigest, credentialName: request.credentialName
        )
        XCTAssertThrowsError(try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: created.id, expectedPreviousDigest: created.contentDigest,
            request: mismatchedTarget
        )) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .invalidRequest)
        }
        XCTAssertTrue(harness.vault.approvalRequests.pendingRequests().isEmpty)
        let ticket = try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: created.id, expectedPreviousDigest: created.contentDigest, request: request
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertEqual(pending.request, request)
        XCTAssertEqual(pending.displayCredentialName, "可信文件名称")
        XCTAssertEqual(try harness.vault.approvalRequests.status(
            requestID: ticket.requestID, capability: ticket.capability, operationRequest: request
        ), .pending)
    }
    func testFileCreateApprovalKeepsTargetName() throws {
        let harness = try makeManagedHarness()
        let request = BrokerApprovalOperationRequest(
            operationID: "create-display-metadata", credentialID: "new-file",
            targetID: "新建文件名称", operation: .create,
            payloadDigest: String(repeating: "b", count: 64)
        )
        _ = try harness.vault.submitFileWriteApprovalIfCurrent(
            credentialID: request.credentialID, expectedPreviousDigest: nil, request: request
        )
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().first)
        XCTAssertNil(pending.trustedCredentialName)
        XCTAssertEqual(pending.displayCredentialName, "新建文件名称")
        XCTAssertEqual(pending.request, request)
    }
    func testDigestReadAndApprovalSubmitBlockAnInterveningMutation() throws {
        let harness = try makeManagedHarness()
        let source = harness.directory.appendingPathComponent("id_ed25519")
        try Data("ssh-ed25519 AAAA fixture-key".utf8).write(to: source)
        let created = try harness.vault.createFileCredential(
            FileCredentialInput(
                name: "Laptop SSH",
                snapshot: try FileImport.freeze(url: source)
            ),
            using: .allow
        )
        let mutationStarted = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let vault = FileCredentialVaultBox(harness.vault)
        let replacement = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("critical-staging"),
            submitFrozenApproval: { credentialID, expectedDigest, request in
                try harness.vault.submitFileWriteApprovalIfCurrent(
                    credentialID: credentialID,
                    expectedPreviousDigest: expectedDigest,
                    request: request,
                    beforeSubmit: {
                        DispatchQueue.global().async {
                            mutationStarted.signal()
                            _ = try? vault.value.updateFileCredential(
                                id: created.id,
                                FileCredentialInput(
                                    name: "Laptop SSH",
                                    snapshot: FileImport.FrozenFile(
                                        originalFilename: "AuthKey.p8",
                                        bytes: replacement,
                                        byteSize: replacement.count,
                                        contentDigest: Data(SHA256.hash(data: replacement))
                                    )
                                ),
                                using: .allow
                            )
                            mutationFinished.signal()
                        }
                        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 1), .success)
                        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 0.1), .timedOut)
                    }
                )
            }
        )
        let uploadBytes = Data("approved-rotation".utf8)
        let upload = try coordinator.begin(
            operationID: "freeze-critical-section",
            credentialID: created.id,
            targetID: created.id,
            operation: .modify,
            originalFilename: "next.p8",
            expectedByteCount: uploadBytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: uploadBytes
        )
        let ticket = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            try harness.vault.approvalRequests.status(
                requestID: ticket.requestID,
                capability: ticket.capability
            ),
            .cancelled
        )
    }
    func testCoordinatorPublicCommitCreatesAnAskFileCredential() throws {
        let harness = try makeManagedHarness()
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("create-staging")
        )
        let credentialID = UUID().uuidString
        let bytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let upload = try coordinator.begin(
            operationID: "agent-create-file",
            credentialID: credentialID,
            targetID: "Agent Created File",
            operation: .create,
            originalFilename: "AuthKey.p8",
            expectedByteCount: bytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try coordinator.summary(requestID: approval.requestID)
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )

        let created = try XCTUnwrap(
            harness.vault.listTextCredentials().first { $0.id == credentialID }
        )
        XCTAssertEqual(created.name, "Agent Created File")
        XCTAssertEqual(created.permission, .ask)
        XCTAssertEqual(created.payloadKind, .file)
        XCTAssertEqual(created.contentDigest, Self.binaryDigestHex)
        let revealed = try harness.vault.revealTextCredential(id: credentialID, using: .allow)
        XCTAssertEqual(revealed.fileBytes, bytes)
        XCTAssertEqual(revealed.originalFilename, "AuthKey.p8")
    }
    func testCreateNameIsBoundToThePersistedDisplayNameBeforeApproval() throws {
        let harness = try makeManagedHarness()
        let coordinator = try makeAgentCoordinator(
            harness,
            stagingDirectory: harness.directory.appendingPathComponent("name-staging")
        )
        let bytes = Data([0x00, 0x01, 0x02, 0x03, 0xFF])
        let credentialID = UUID().uuidString
        let upload = try coordinator.begin(
            operationID: "trimmed-create-name",
            credentialID: credentialID,
            targetID: "  Prod Key  ",
            operation: .create,
            originalFilename: "AuthKey.p8",
            expectedByteCount: bytes.count
        )
        try coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try coordinator.summary(requestID: approval.requestID)
        XCTAssertEqual(summary.targetID, "Prod Key")
        _ = try coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        try coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        )
        let created = try XCTUnwrap(
            harness.vault.listTextCredentials().first { $0.id == credentialID }
        )
        XCTAssertEqual(created.name, "Prod Key")

        for invalidName in ["   ", "Bad\nName", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try coordinator.begin(
                operationID: UUID().uuidString,
                credentialID: UUID().uuidString,
                targetID: invalidName,
                operation: .create,
                originalFilename: "key.bin",
                expectedByteCount: 1
            )) { error in
                guard case VaultError.invalidCredentialName = error else {
                    return XCTFail("expected invalidCredentialName, got \(error)")
                }
            }
        }
    }
}
