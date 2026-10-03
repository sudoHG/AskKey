import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

/// Review-only counterexamples. Every byte is synthetic and every writable path
/// belongs to an explicit test directory; no singleton, Keychain, or socket.
final class AuditBrokerBoundaryTests: XCTestCase {
    func testAllowedRuntimeRetransmissionDoesNotSpawnTwice() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        try harness.createAllowedCredential()
        let marker = harness.directory.appendingPathComponent("spawn-count")
        let runtime = BrokerTextRuntime(resolveCredentials: { request, cancellation in
            try harness.vault.brokerTextCredentials(for: request, cancellation: cancellation)
        })
        let request = BrokerTextRunRequest(
            operationID: "audit-stable-runtime-operation",
            command: ["/bin/sh", "-c", "printf x >> \"$1\"", "audit", marker.path],
            credentialNames: ["AUDIT_TOKEN"],
            workingDirectory: harness.directory.path,
            inheritedEnvironment: [:]
        )
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? nullInput.close(); try? nullOutput.close() }
        XCTAssertEqual(
            try runtime.run(
                request,
                standardInputFD: nullInput.fileDescriptor,
                standardOutputFD: nullOutput.fileDescriptor,
                standardErrorFD: nullOutput.fileDescriptor
            ),
            .exited(0)
        )
        // A cached result or refusal is acceptable for this at-most-once probe.
        // Neither permits the identical operation to execute a second time.
        _ = try? runtime.run(
            request,
            standardInputFD: nullInput.fileDescriptor,
            standardOutputFD: nullOutput.fileDescriptor,
            standardErrorFD: nullOutput.fileDescriptor
        )
        XCTAssertEqual(
            try Data(contentsOf: marker),
            Data("x".utf8),
            "Retransmitting an allowed runtime operation must not repeat its target side effect"
        )
    }

    func testApprovedAgentTextModificationPreventsPreparedOldValueSpawn() throws {
        try assertAgentWriteInvalidatesPreparedRuntime(action: .modify(name: "AUDIT_TOKEN", value: "synthetic-new"))
    }

    func testApprovedAgentTextDeletionPreventsPreparedOldValueSpawn() throws {
        try assertAgentWriteInvalidatesPreparedRuntime(action: .delete(name: "AUDIT_TOKEN"))
    }

    func testAgentCanDeleteWholeFileAndBundleCredentialsAfterApproval() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        let file = try harness.vault.createFileCredential(
            .init(name: "Audit File", snapshot: try .init(originalFilename: "key.pem", bytes: Data("synthetic-file".utf8))),
            using: .allow
        )
        let bundle = try harness.vault.createBundleCredential(
            .init(name: "Audit Bundle", components: [
                .init(name: "TOKEN", value: .text("synthetic-token")),
                .init(name: "KEY_FILE", value: .file(filename: "key.pem", bytes: Data("synthetic-file".utf8))),
            ]),
            using: .allow
        )
        for credential in [file, bundle] {
            let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: .delete(name: credential.name))
            guard case .submitted(let ticket) = try harness.vault.requestAgentTextWrite(request) else {
                return XCTFail("Whole-credential deletion must create a request")
            }
            XCTAssertEqual(ticket.state, .pending)
            _ = try harness.vault.approvalRequests.decide(
                requestID: ticket.requestID, capability: ticket.capability, decision: .once
            )
            let result = try harness.vault.commitAgentTextWrite(
                request, requestID: ticket.requestID, capability: ticket.capability
            )
            XCTAssertEqual(result.credentialID, credential.id)
            XCTAssertEqual(result.state, .completed)
        }
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        XCTAssertEqual(Set(try harness.vault.listRecycledTextCredentials().map(\.id)), Set([file.id, bundle.id]))
    }

    func testCatalogProvidesTheReferenceNeededToModifyAnExistingFile() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        let created = try harness.vault.createFileCredential(
            .init(name: "Audit Existing File", snapshot: try .init(originalFilename: "key.pem", bytes: Data("synthetic-file".utf8))),
            using: .allow
        )
        let item = try XCTUnwrap(harness.vault.brokerCredentialCatalog().first)
        let reference = try XCTUnwrap(item.credentialID)
        XCTAssertEqual(reference, created.id)
        let coordinator = try BrokerFileWriteCoordinator(
            stagingDirectory: harness.directory.appendingPathComponent("uploads"),
            approvals: harness.vault.approvalRequests,
            authenticateReveal: { true },
            commitFrozenFile: { try harness.vault.commitAgentFileWrite($0) },
            submitFrozenApproval: { try harness.vault.submitFileWriteApprovalIfCurrent(
                credentialID: $0, expectedPreviousDigest: $1, request: $2
            ) },
            normalizeCreateTarget: { try harness.vault.normalizeAgentCreateCredentialName($0) },
            resolvePreviousDigest: { try harness.vault.brokerFileContentDigest(credentialID: $0) }
        )
        let replacement = Data("synthetic-rotated-file".utf8)
        let upload = try coordinator.begin(
            operationID: UUID().uuidString, credentialID: reference, targetID: reference,
            operation: .modify, originalFilename: "key.pem", expectedByteCount: replacement.count
        )
        try coordinator.append(uploadID: upload.uploadID, capability: upload.capability, offset: 0, bytes: replacement)
        let ticket = try coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        XCTAssertEqual(ticket.state, .pending)
        _ = try coordinator.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        let summary = try coordinator.summary(requestID: ticket.requestID)
        try coordinator.commit(requestID: ticket.requestID, capability: ticket.capability, expectedDigest: summary.digest)
        XCTAssertEqual(try harness.vault.brokerFileContentDigest(credentialID: reference), summary.digest)
    }

    func testFrozenTextRevealAuthenticatesWithoutOpeningManagementSession() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: .create(name: "Audit New", value: "synthetic-new"))
        guard case .submitted(let ticket) = try harness.vault.requestAgentTextWrite(request) else {
            return XCTFail("Expected pending frozen request")
        }
        harness.vault.endManagementSession()
        XCTAssertThrowsError(try harness.vault.revealAgentTextWrite(
            operationID: request.operationID, requestID: ticket.requestID, capability: ticket.capability, using: .deny
        ))
        XCTAssertEqual(try harness.vault.revealAgentTextWrite(
            operationID: request.operationID, requestID: ticket.requestID, capability: ticket.capability, using: .allow
        ), request.action)
        XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertThrowsError(try harness.vault.listTextCredentials())
    }

    func testMixedCredentialUsesOneFrozenApprovalAndSubsetModificationPreservesOtherComponents() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        let coordinator = try BrokerFileWriteCoordinator(
            stagingDirectory: harness.directory.appendingPathComponent("component-uploads"),
            approvals: harness.vault.approvalRequests, authenticateReveal: { true }, commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, _ in throw BrokerFileWriteError.invalidRequest },
            normalizeCreateTarget: { $0 })
        let operationID = UUID().uuidString
        let bytes = Data("synthetic-component-file".utf8)
        guard case .upload(let upload) = try coordinator.handle(.beginComponent(.init(
            operationID: operationID, originalFilename: "key.pem", expectedByteCount: bytes.count))) else {
            return XCTFail("Expected component staging")
        }
        try coordinator.append(uploadID: upload.uploadID, capability: upload.capability, offset: 0, bytes: bytes)
        let reference = try coordinator.freezeComponent(uploadID: upload.uploadID, capability: upload.capability)
        XCTAssertThrowsError(try coordinator.resolveComponent(reference, operationID: "different-operation"))
        let request = AgentTextWriteRequest(operationID: operationID, action: .createBundle(name: "Mixed Credential", components: [
            .init(name: "token", value: .text("synthetic-token"), delivery: .environmentVariable("SERVICE_TOKEN")),
            .init(name: "key", value: .file(reference), delivery: .temporaryFile("SERVICE_KEY")),
            .init(name: "memo", value: .text("synthetic-note"), delivery: .none, masked: false),
        ]))
        guard case .submitted(let ticket) = try harness.vault.requestAgentTextWrite(request,
            fileResolver: { try coordinator.resolveComponent($0, operationID: operationID) }) else {
            return XCTFail("Expected one approval")
        }
        let summary = try harness.vault.frozenAgentWriteSummary(operationID: operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        XCTAssertEqual(summary.after.count, 3)
        XCTAssertNotNil(summary.afterDigest)
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
        // Once frozen, staging can disappear; exact replay must use the immutable snapshot.
        try coordinator.cancelUpload(uploadID: upload.uploadID, capability: upload.capability)
        guard case .submitted(let replay) = try harness.vault.requestAgentTextWrite(request) else {
            return XCTFail("Expected frozen replay")
        }
        XCTAssertEqual(replay.requestID, ticket.requestID)
        let swapped = AgentTextWriteRequest(operationID: operationID, action: .createBundle(name: "Mixed Credential", components: [
            .init(name: "token", value: .text("swapped"), delivery: .environmentVariable("SERVICE_TOKEN")),
        ]))
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(swapped))
        _ = try harness.vault.approvalRequests.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        _ = try harness.vault.commitAgentTextWrite(request, requestID: ticket.requestID, capability: ticket.capability)
        let modify = AgentTextWriteRequest(operationID: UUID().uuidString,
            action: .modifyBundle(name: "Mixed Credential", changes: [
                .upsert(.init(name: "token", value: .text("synthetic-updated"), delivery: .environmentVariable("NEW_TOKEN"))),
            ]))
        guard case .submitted(let modifyTicket) = try harness.vault.requestAgentTextWrite(modify) else {
            return XCTFail("Expected whole-credential modification")
        }
        harness.vault.endManagementSession()
        XCTAssertThrowsError(try harness.vault.revealFrozenCredentialWrite(operationID: modify.operationID,
            requestID: modifyTicket.requestID, capability: modifyTicket.capability, using: .deny))
        let reveal = try harness.vault.revealFrozenCredentialWrite(operationID: modify.operationID,
            requestID: modifyTicket.requestID, capability: modifyTicket.capability, using: .allow)
        XCTAssertEqual(reveal.before.count, 3)
        XCTAssertEqual(reveal.after.count, 3)
        XCTAssertEqual(reveal.after[1], reveal.before[1])
        XCTAssertEqual(reveal.after[2], reveal.before[2])
        XCTAssertEqual(reveal.after[0].delivery, .environmentVariable("NEW_TOKEN"))
        XCTAssertThrowsError(try harness.vault.listTextCredentials())
        _ = try harness.vault.approvalRequests.decide(requestID: modifyTicket.requestID,
            capability: modifyTicket.capability, decision: .deny)
        XCTAssertThrowsError(try harness.vault.revealFrozenCredentialWrite(operationID: modify.operationID,
            requestID: modifyTicket.requestID, capability: modifyTicket.capability, using: .allow))
    }

    func testDuplicateComponentMappingsRejectWholeCreation() throws {
        let harness = try AuditBrokerHarness()
        defer { harness.cleanup() }
        let request = AgentTextWriteRequest(operationID: UUID().uuidString,
            action: .createBundle(name: "Invalid mappings", components: [
                .init(name: "first", value: .text("one"), delivery: .environmentVariable("SAME")),
                .init(name: "second", value: .text("two"), delivery: .temporaryFile("SAME")),
            ]))
        XCTAssertThrowsError(try harness.vault.requestAgentTextWrite(request))
        XCTAssertTrue(try harness.vault.brokerCredentialCatalog().isEmpty)
    }

    private func assertAgentWriteInvalidatesPreparedRuntime(
        action: AgentTextWriteAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let harness = try AuditBrokerHarness()
        // Cleanup only after the worker has joined, including a future fix that
        // waits for the runtime lease. A stuck worker retains its isolated files.
        var workerJoined = true
        defer { if workerJoined { harness.cleanup() } }
        try harness.createAllowedCredential()
        let write = AgentTextWriteRequest(operationID: UUID().uuidString, action: action)
        guard case .submitted(let ticket) = try harness.vault.requestAgentTextWrite(write) else {
            return XCTFail("Expected a fresh synthetic write request", file: file, line: line)
        }
        _ = try harness.vault.approvalRequests.decide(
            requestID: ticket.requestID,
            capability: ticket.capability,
            decision: .once
        )
        let marker = harness.directory.appendingPathComponent("released-value")
        let completion = DispatchSemaphore(value: 0)
        let writeOutcome = AuditBrokerWriteOutcome()
        let cancellation = BrokerCancellation()
        let runtime = BrokerTextRuntime(
            resolveCredentials: { request, cancellation in
                try harness.vault.brokerTextCredentials(for: request, cancellation: cancellation)
            },
            beforeSpawn: {
                // Resolution/decryption has completed; the target does not exist.
                DispatchQueue.global().async {
                    do {
                        let result = try harness.vault.commitAgentTextWrite(
                            write,
                            requestID: ticket.requestID,
                            capability: ticket.capability
                        )
                        writeOutcome.set(result: result, error: nil)
                    } catch {
                        writeOutcome.set(result: nil, error: error)
                    }
                    completion.signal()
                }
                if completion.wait(timeout: .now() + 0.5) == .success {
                    // Preserve a completion signal for the outer bounded join.
                    completion.signal()
                } else {
                    // A corrected exclusive gate may block the mutation until
                    // this lease ends. Throwing unwinds it and allows safe join.
                    cancellation.cancel()
                    throw AuditBrokerProbeError.mutationWaitTimedOut
                }
            }
        )
        let nullInput = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        let nullOutput = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        defer { try? nullInput.close(); try? nullOutput.close() }
        workerJoined = false
        do {
            _ = try runtime.run(
                .init(
                    operationID: UUID().uuidString,
                    command: ["/bin/sh", "-c", "printf '%s' \"$TOKEN\" > \"$1\"", "audit", marker.path],
                    credentialNames: ["AUDIT_TOKEN"],
                    workingDirectory: harness.directory.path,
                    inheritedEnvironment: [:]
                ),
                standardInputFD: nullInput.fileDescriptor,
                standardOutputFD: nullOutput.fileDescriptor,
                standardErrorFD: nullOutput.fileDescriptor,
                cancellation: cancellation
            )
        } catch {
            // Revoked delivery should fail closed; setup and commit are asserted
            // independently so an unrelated write failure cannot turn this green.
        }
        workerJoined = completion.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(workerJoined, "Synthetic write worker must finish after runtime lease release", file: file, line: line)
        guard workerJoined else { return }
        let outcome = writeOutcome.get()
        XCTAssertNil(outcome.error, "Approved synthetic write must commit", file: file, line: line)
        XCTAssertEqual(outcome.result?.state, .completed, file: file, line: line)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "A prepared runtime must not spawn with old material after an approved Agent write commits",
            file: file,
            line: line
        )
        if FileManager.default.fileExists(atPath: marker.path) {
            // Diagnostic content is synthetic, never a real saved credential.
            XCTAssertNotEqual(try Data(contentsOf: marker), Data("synthetic-old".utf8), file: file, line: line)
        }
    }
}

private enum AuditBrokerProbeError: Error {
    case mutationWaitTimedOut
}

private final class AuditBrokerHarness: @unchecked Sendable {
    let directory: URL
    let store: VaultStore
    let deliveries: FileDeliveryManager
    let vault: Vault

    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AskKeyAuditBroker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        store = try VaultStore(path: directory.appendingPathComponent("synthetic-vault.db").path)
        deliveries = try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries", isDirectory: true))
        vault = Vault(
            store: store,
            key: VaultCrypto.generateKey(),
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true }),
            fileDeliveryManager: deliveries
        )
        try vault.beginManagementSession(using: .allow)
    }

    func createAllowedCredential() throws {
        _ = try vault.createTextCredential(
            .init(name: "AUDIT_TOKEN", value: "synthetic-old", environmentVariable: "TOKEN", permission: .allowed),
            using: .allow
        )
    }

    func cleanup() {
        deliveries.cleanupAll()
        try? store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class AuditBrokerWriteOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: AgentTextWriteResult?
    private var error: Error?

    func set(result: AgentTextWriteResult?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        self.result = result
        self.error = error
    }

    func get() -> (result: AgentTextWriteResult?, error: Error?) {
        lock.lock(); defer { lock.unlock() }
        return (result, error)
    }
}
