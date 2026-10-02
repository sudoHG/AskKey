import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyCore

/// Exercises the legacy public file protocol against the real Vault transaction.
/// Every key, credential, socket-independent coordinator and database is synthetic.
final class LegacyFileWriteTransactionTests: XCTestCase {
    func testCreateAndRotationReplayReturnCompletionWithoutRepeatingTheMutation() throws {
        for operation in [BrokerApprovalOperation.create, .modify] {
            let root = try makeRoot()
            let harness = try LegacyFileTransactionHarness(root: root)
            defer { harness.close() }
            let credentialID = try harness.prepareTarget(operation)
            let coordinator = try harness.coordinator()
            let staged = try harness.stage(operation, credentialID: credentialID, coordinator: coordinator)
            try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
            let committed = try XCTUnwrap(harness.store.fetchCredential(id: credentialID))
            let receipt = try XCTUnwrap(harness.store.fetchAgentWriteOperation(operationID: staged.operationID))
            XCTAssertEqual(receipt.resultDigest, staged.digest)
            XCTAssertEqual(receipt.requestId, staged.requestID)
            XCTAssertEqual(receipt.payloadDigest, staged.approvalDigest)
            XCTAssertEqual(try harness.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_write_operations") }, 1)
            XCTAssertThrowsError(try coordinator.commit(requestID: staged.requestID, capability: "wrong", expectedDigest: staged.digest))
            XCTAssertThrowsError(try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: String(repeating: "0", count: 64)))
            try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
            let replay = try coordinator.freeze(uploadID: staged.uploadID, capability: staged.uploadCapability)
            XCTAssertEqual(replay.requestID, staged.requestID)
            XCTAssertEqual(replay.capability, staged.capability)
            XCTAssertEqual(replay.state, .consumed)
            XCTAssertEqual(try coordinator.handle(.freeze(.init(uploadID: staged.uploadID,
                capability: staged.uploadCapability))), .approval(replay))
            XCTAssertThrowsError(try coordinator.freeze(uploadID: staged.uploadID, capability: "wrong-upload-capability"))
            XCTAssertEqual(try harness.store.fetchCredential(id: credentialID)?.encryptedPayload, committed.encryptedPayload)
            XCTAssertEqual(try harness.store.fetchCredential(id: credentialID)?.updatedAt, committed.updatedAt)
            XCTAssertEqual(try harness.vault.committedAgentFileWriteStatus(requestID: staged.requestID, capability: staged.capability), .completed)

            // A receipt describes the old completed write, not the current file.
            // Replaying it after a later human rotation must not restore old bytes.
            _ = try harness.vault.updateFileCredential(id: credentialID,
                .init(name: "Legacy receipt file", snapshot: try .init(originalFilename: "later.pem", bytes: Data("later-human-file".utf8))), using: .allow)
            let later = try XCTUnwrap(harness.store.fetchCredential(id: credentialID))
            try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
            XCTAssertEqual(try harness.store.fetchCredential(id: credentialID)?.encryptedPayload, later.encryptedPayload)
        }
    }

    func testReceiptInsertionFailureRollsBackCreateAndRotationTogether() throws {
        for operation in [BrokerApprovalOperation.create, .modify] {
            let root = try makeRoot()
            let harness = try LegacyFileTransactionHarness(root: root)
            defer { harness.close() }
            let credentialID = try harness.prepareTarget(operation)
            let before = try harness.store.fetchCredential(id: credentialID)
            let coordinator = try harness.coordinator()
            let staged = try harness.stage(operation, credentialID: credentialID, coordinator: coordinator)
            try harness.store.db.write { db in
                try db.execute(sql: "CREATE TRIGGER reject_file_receipt BEFORE INSERT ON agent_write_operations BEGIN SELECT RAISE(ABORT, 'synthetic receipt failure'); END")
            }
            XCTAssertThrowsError(try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest))
            XCTAssertNil(try harness.store.fetchAgentWriteOperation(operationID: staged.operationID))
            let afterFailure = try harness.store.fetchCredential(id: credentialID)
            XCTAssertEqual(afterFailure?.encryptedPayload, before?.encryptedPayload)
            XCTAssertEqual(afterFailure?.contentDigest, before?.contentDigest)
            XCTAssertEqual(try harness.vault.approvalRequests.status(requestID: staged.requestID, capability: staged.capability), .approved)
            try harness.store.db.write { try $0.execute(sql: "DROP TRIGGER reject_file_receipt") }
            try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
            XCTAssertEqual(try harness.store.fetchAgentWriteOperation(operationID: staged.operationID)?.resultDigest, staged.digest)
        }
    }

    func testAbruptExitAfterFileDatabaseCommitRecoversCreateAndRotationReceipts() throws {
        for operation in [BrokerApprovalOperation.create, .modify] {
            let root = try makeRoot()
            try runAbruptCommit(root: root, operation: operation)
            // This is a new Vault/store/coordinator after an actual SIGKILL.
            // No old upload session, approval state or in-memory receipt survives.
            let harness = try LegacyFileTransactionHarness(root: root)
            defer { harness.close() }
            let staged = try JSONDecoder().decode(LegacyFileReceiptFixture.self,
                from: Data(contentsOf: root.appendingPathComponent("receipt.json")))
            let record = try XCTUnwrap(harness.store.fetchCredential(id: staged.credentialID))
            let receipt = try XCTUnwrap(harness.store.fetchAgentWriteOperation(operationID: staged.operationID))
            XCTAssertEqual(receipt.resultDigest, staged.digest)
            XCTAssertEqual(receipt.payloadDigest, staged.approvalDigest)
            XCTAssertThrowsError(try harness.vault.approvalRequests.status(requestID: staged.requestID, capability: staged.capability))
            let coordinator = try harness.coordinator(afterCommit: { _ in XCTFail("Recovery must not run the business write again") })
            try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
            XCTAssertEqual(try harness.vault.committedAgentFileWriteStatus(requestID: staged.requestID, capability: staged.capability), .completed)
            XCTAssertThrowsError(try harness.vault.committedAgentFileWriteStatus(requestID: staged.requestID, capability: "wrong"))
            XCTAssertNil(try harness.vault.committedAgentFileWriteStatus(requestID: "unknown-request", capability: staged.capability))
            let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: {
                try harness.vault.committedAgentFileWriteStatus(requestID: $0, capability: $1)
            })
            let status = handler.handle(.init(version: BrokerProtocolVersion.current,
                method: "request.status", requestID: staged.requestID, capability: staged.capability))
            XCTAssertEqual(status, .success(.requestStatus(.completed)))
            XCTAssertEqual(handler.handle(.init(version: BrokerProtocolVersion.current,
                method: "request.status", requestID: staged.requestID, capability: "wrong")), .failure(.requestNotFound))
            XCTAssertFalse(String(decoding: try JSONEncoder().encode(status), as: UTF8.self).contains("synthetic-committed-file"))
            XCTAssertEqual(try harness.store.fetchCredential(id: staged.credentialID)?.encryptedPayload, record.encryptedPayload)
            XCTAssertEqual(try harness.store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_write_operations") }, 1)
        }
    }

    func testAbruptFileCommitProcess() throws {
        guard let path = ProcessInfo.processInfo.environment["ASKKEY_FILE_COMMIT_CRASH_ROOT"],
              let raw = ProcessInfo.processInfo.environment["ASKKEY_FILE_COMMIT_OPERATION"],
              let operation = BrokerApprovalOperation(rawValue: raw) else {
            throw XCTSkip("Only the isolated file-commit crash subprocess invokes this entry")
        }
        let root = URL(fileURLWithPath: path)
        guard root.lastPathComponent.hasPrefix("AskKeyFileCommitCrash-"),
              try Data(contentsOf: root.appendingPathComponent("fixture-marker")) == Data("synthetic file commit crash".utf8) else {
            throw BrokerFileWriteError.invalidRequest
        }
        let harness = try LegacyFileTransactionHarness(root: root)
        let credentialID = try harness.prepareTarget(operation)
        let coordinator = try harness.coordinator(afterCommit: { _ in
            // Runs after SQLite commits both the file and ledger, before the
            // coordinator can consume the memory approval or clean staging.
            _ = Darwin.kill(getpid(), SIGKILL)
            _exit(99)
        })
        let staged = try harness.stage(operation, credentialID: credentialID, coordinator: coordinator)
        try JSONEncoder().encode(staged).write(to: root.appendingPathComponent("receipt.json"), options: .atomic)
        try coordinator.commit(requestID: staged.requestID, capability: staged.capability, expectedDigest: staged.digest)
        XCTFail("Configured post-transaction crash was not reached")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyFileCommitCrash-\(UUID().uuidString)", isDirectory: true)
        for directory in [root, root.appendingPathComponent("home"), root.appendingPathComponent("tmp")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("synthetic file commit crash".utf8).write(to: root.appendingPathComponent("fixture-marker"))
        // The only on-disk key is generated exclusively for this synthetic test.
        let keyURL = root.appendingPathComponent("synthetic-key")
        try VaultCrypto.keyToData(VaultCrypto.generateKey()).write(to: keyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func runAbruptCommit(root: URL, operation: BrokerApprovalOperation) throws {
        let log = root.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]))
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["xctest", "-XCTest", "AskKeyCoreTests.LegacyFileWriteTransactionTests/testAbruptFileCommitProcess", Bundle(for: LegacyFileWriteTransactionTests.self).bundleURL.path]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": root.appendingPathComponent("home").path,
            "CFFIXED_USER_HOME": root.appendingPathComponent("home").path, "TMPDIR": root.appendingPathComponent("tmp").path + "/",
            "ASKKEY_FILE_COMMIT_CRASH_ROOT": root.path, "ASKKEY_FILE_COMMIT_OPERATION": operation.rawValue]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else { return XCTFail("File commit subprocess exceeded 15 seconds") }
        process.waitUntilExit()
        let diagnostics = String(decoding: try Data(contentsOf: log).prefix(8192), as: UTF8.self)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal, diagnostics)
        XCTAssertEqual(process.terminationStatus, SIGKILL, diagnostics)
    }
}

private struct LegacyFileReceiptFixture: Codable {
    let operationID: String
    let credentialID: String
    let requestID: String
    let capability: String
    let digest: String
    let approvalDigest: String
    let uploadID: String
    let uploadCapability: String
}

private final class LegacyFileTransactionHarness: @unchecked Sendable {
    let root: URL
    let store: VaultStore
    let vault: Vault
    let deliveries: FileDeliveryManager
    init(root: URL) throws {
        self.root = root
        store = try VaultStore(path: root.appendingPathComponent("synthetic-vault.db").path)
        deliveries = try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        vault = Vault(store: store, key: VaultCrypto.keyFromData(try Data(contentsOf: root.appendingPathComponent("synthetic-key"))),
            approvalRequests: BrokerApprovalStateMachine(authenticate: { _ in true }), fileDeliveryManager: deliveries)
        try vault.beginManagementSession(using: .allow)
    }
    func close() { deliveries.cleanupAll(); try? store.close() }
    func prepareTarget(_ operation: BrokerApprovalOperation) throws -> String {
        if operation == .create { return "synthetic-created-file" }
        return try vault.createFileCredential(.init(name: "Legacy receipt file",
            snapshot: .init(originalFilename: "old.pem", bytes: Data("synthetic-old-file".utf8))), using: .allow).id
    }
    func coordinator(afterCommit: @escaping @Sendable (BrokerFrozenFile) throws -> Void = { _ in }) throws -> BrokerFileWriteCoordinator {
        try BrokerFileWriteCoordinator(stagingDirectory: root.appendingPathComponent("uploads"), approvals: vault.approvalRequests,
            authenticateReveal: { true }, commitFrozenFile: { file in try self.vault.commitAgentFileWrite(file); try afterCommit(file) },
            submitFrozenApproval: { try self.vault.submitFileWriteApprovalIfCurrent(credentialID: $0, expectedPreviousDigest: $1, request: $2) },
            normalizeCreateTarget: { try self.vault.normalizeAgentCreateCredentialName($0) },
            resolvePreviousDigest: { try self.vault.brokerFileContentDigest(credentialID: $0) },
            completedFileCommit: { try self.vault.completedAgentFileWrite(requestID: $0, capability: $1, expectedDigest: $2) })
    }
    func stage(_ operation: BrokerApprovalOperation, credentialID: String, coordinator: BrokerFileWriteCoordinator) throws -> LegacyFileReceiptFixture {
        let operationID = UUID().uuidString
        let bytes = Data("synthetic-committed-file".utf8)
        let upload = try coordinator.begin(operationID: operationID, credentialID: credentialID,
            targetID: operation == .create ? "Legacy receipt file" : credentialID,
            operation: operation, originalFilename: "key.pem", expectedByteCount: bytes.count)
        try coordinator.append(uploadID: upload.uploadID, capability: upload.capability, offset: 0, bytes: bytes)
        let ticket = try coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        let frozen = try coordinator.reveal(requestID: ticket.requestID)
        _ = try coordinator.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        return .init(operationID: operationID, credentialID: credentialID, requestID: ticket.requestID, capability: ticket.capability,
            digest: frozen.digest, approvalDigest: frozen.approvalPayloadDigest, uploadID: upload.uploadID, uploadCapability: upload.capability)
    }
}
