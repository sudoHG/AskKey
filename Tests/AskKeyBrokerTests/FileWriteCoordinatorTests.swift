import Foundation
import XCTest
@testable import AskKeyBroker

final class FileWriteCoordinatorTests: XCTestCase {
    func testStagingPathThatIsAFileIsATypedFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyStagingType-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("file-write-staging")
        try Data("not-a-directory".utf8).write(to: staging)

        XCTAssertThrowsError(try makeCoordinator(stagingDirectory: staging)) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .stagingNotADirectory)
            XCTAssertFalse(String(describing: error).contains(NSHomeDirectory()))
        }
    }

    func testStagingParentWithoutWritePermissionIsATypedFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyStagingPerm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: directory.path
            )
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: directory.path
        )
        let staging = directory.appendingPathComponent("file-write-staging", isDirectory: true)

        XCTAssertThrowsError(try makeCoordinator(stagingDirectory: staging)) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .stagingPermissionDenied)
        }
    }

    func testStagingSucceedsAfterATypedDirectoryConditionIsFixed() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyStagingRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("file-write-staging")
        try Data("not-a-directory".utf8).write(to: staging)
        XCTAssertThrowsError(try makeCoordinator(stagingDirectory: staging)) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .stagingNotADirectory)
        }

        try FileManager.default.removeItem(at: staging)
        XCTAssertNoThrow(try makeCoordinator(stagingDirectory: staging))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let permissions = try FileManager.default.attributesOfItem(atPath: staging.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.uint16Value ?? 0) & 0o777, 0o700)
    }

    func testOutOfOrderChunkIsRejectedBeforeApprovalExists() throws {
        let harness = try makeHarness()
        let upload = try harness.coordinator.begin(
            operationID: "upload-operation",
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .modify,
            originalFilename: "AuthKey.p8",
            expectedByteCount: 6
        )

        XCTAssertThrowsError(
            try harness.coordinator.append(
                uploadID: upload.uploadID,
                capability: upload.capability,
                offset: 3,
                bytes: Data("def".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .outOfOrderChunk)
        }
        XCTAssertThrowsError(
            try harness.coordinator.freeze(
                uploadID: upload.uploadID,
                capability: upload.capability
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .truncatedUpload)
        }
    }

    func testCapabilityAndSizeLimitsFailBeforeFreeze() throws {
        let harness = try makeHarness()
        XCTAssertThrowsError(
            try harness.coordinator.begin(
                operationID: "path-input",
                credentialID: "credential-id",
                targetID: "credential-id",
                operation: .modify,
                originalFilename: "/tmp/replaceable.key",
                expectedByteCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .invalidRequest)
        }
        XCTAssertThrowsError(
            try harness.coordinator.begin(
                operationID: "too-large",
                credentialID: "credential-id",
                targetID: "credential-id",
                operation: .modify,
                originalFilename: "key.bin",
                expectedByteCount: BrokerFileWriteCoordinator.maximumByteCount + 1
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .tooLarge)
        }

        let upload = try begin(harness, operationID: "bounded", expectedByteCount: 3)
        XCTAssertThrowsError(
            try harness.coordinator.append(
                uploadID: upload.uploadID,
                capability: "wrong-capability",
                offset: 0,
                bytes: Data("abc".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .invalidCapability)
        }
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: Data("abc".utf8)
        )
        XCTAssertThrowsError(
            try harness.coordinator.append(
                uploadID: upload.uploadID,
                capability: upload.capability,
                offset: 3,
                bytes: Data("d".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .tooLarge)
        }
    }

    func testStagingNeverContainsPlaintext() throws {
        let harness = try makeHarness()
        let secret = Data("PRIVATE-KEY-MATERIAL-DO-NOT-LOG".utf8)
        let upload = try begin(harness, operationID: "encrypted", expectedByteCount: secret.count)
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: secret
        )
        let staged = try FileManager.default.contentsOfDirectory(
            at: harness.directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(staged.count, 1)
        XCTAssertFalse(try Data(contentsOf: staged[0]).contains(secret))
        _ = try harness.coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        XCTAssertFalse(try Data(contentsOf: staged[0]).contains(secret))
    }

    func testUnfrozenUploadSessionsAreBounded() throws {
        let harness = try makeHarness()
        for index in 0..<BrokerFileWriteCoordinator.maximumUploadSessions {
            XCTAssertNoThrow(try begin(
                harness,
                operationID: "pending-\(index)",
                expectedByteCount: 0
            ))
        }
        XCTAssertThrowsError(try begin(
            harness,
            operationID: "overflow",
            expectedByteCount: 0
        )) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .capacityReached)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).count,
            BrokerFileWriteCoordinator.maximumUploadSessions
        )
    }

    func testExpiredUploadsReleaseCapacityAndStartupRemovesCiphertextResidue() throws {
        let clock = LockedClock(Date(timeIntervalSince1970: 0))
        let harness = try makeHarness(uploadTTL: 1, clock: { clock.now })
        for index in 0..<BrokerFileWriteCoordinator.maximumUploadSessions {
            _ = try begin(harness, operationID: "expiring-\(index)", expectedByteCount: 0)
        }
        clock.now = Date(timeIntervalSince1970: 2)
        XCTAssertNoThrow(try begin(harness, operationID: "after-expiry", expectedByteCount: 0))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).count,
            1
        )

        let residue = harness.directory.appendingPathComponent("upload-orphaned-ciphertext")
        try Data("old encrypted generation".utf8).write(to: residue)
        _ = try BrokerFileWriteCoordinator(
            stagingDirectory: harness.directory,
            approvals: BrokerApprovalStateMachine(),
            authenticateReveal: { false },
            commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in
                try BrokerApprovalStateMachine().submit(request)
            },
            normalizeCreateTarget: { $0 }
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).isEmpty)
    }

    func testApprovalBindsFilenameAsWellAsFileBytes() throws {
        let harness = try makeHarness()
        let bytes = Data("same-file-bytes".utf8)
        let first = try harness.coordinator.begin(
            operationID: "filename-bound",
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .modify,
            originalFilename: "first.p8",
            expectedByteCount: bytes.count
        )
        try harness.coordinator.append(
            uploadID: first.uploadID,
            capability: first.capability,
            offset: 0,
            bytes: bytes
        )
        _ = try harness.coordinator.freeze(uploadID: first.uploadID, capability: first.capability)

        let swapped = try harness.coordinator.begin(
            operationID: "filename-bound",
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .modify,
            originalFilename: "second.p8",
            expectedByteCount: bytes.count
        )
        try harness.coordinator.append(
            uploadID: swapped.uploadID,
            capability: swapped.capability,
            offset: 0,
            bytes: bytes
        )
        XCTAssertThrowsError(
            try harness.coordinator.freeze(
                uploadID: swapped.uploadID,
                capability: swapped.capability
            )
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
    }

    func testTargetChangeBetweenBeginAndFreezeFailsBeforeApproval() throws {
        let target = LockedDigest(String(repeating: "a", count: 64))
        let harness = try makeHarness(resolvePreviousDigest: { _ in target.value })
        let bytes = Data("rotated-file".utf8)
        let upload = try begin(
            harness,
            operationID: "target-changed-before-freeze",
            expectedByteCount: bytes.count
        )
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )

        target.value = String(repeating: "b", count: 64)
        XCTAssertThrowsError(
            try harness.coordinator.freeze(
                uploadID: upload.uploadID,
                capability: upload.capability
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .targetChanged)
        }
    }

    func testTargetChangeAfterFreezeFailsBeforeCommitTransaction() throws {
        let originalDigest = String(repeating: "a", count: 64)
        let target = LockedDigest(originalDigest)
        let harness = try makeHarness(resolvePreviousDigest: { _ in target.value })
        let bytes = Data("approved-rotation".utf8)
        let upload = try begin(
            harness,
            operationID: "target-changed-before-commit",
            expectedByteCount: bytes.count
        )
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try harness.coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let frozen = try harness.coordinator.reveal(requestID: approval.requestID)
        XCTAssertEqual(frozen.previousDigest, originalDigest)
        _ = try harness.coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )

        target.value = String(repeating: "b", count: 64)
        var transactionCalled = false
        XCTAssertThrowsError(try harness.coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: frozen.digest,
            consume: { _ in transactionCalled = true }
        )) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .targetChanged)
        }
        XCTAssertFalse(transactionCalled)
    }

    func testPathReplacementCannotChangeFrozenOrCommittedBytes() throws {
        let previousDigest = String(repeating: "a", count: 64)
        let harness = try makeHarness(resolvePreviousDigest: { _ in previousDigest })
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeySource-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        let original = Data("original-key-bytes".utf8)
        let replacement = Data("replacement-key!!".utf8)
        try original.write(to: source)
        let upload = try begin(harness, operationID: "path-swap", expectedByteCount: original.count)
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: try Data(contentsOf: source)
        )
        try replacement.write(to: source)

        let approval = try harness.coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try harness.coordinator.summary(requestID: approval.requestID)
        XCTAssertTrue(summary.payloadMasked)
        XCTAssertEqual(summary.targetID, "credential-id")
        XCTAssertEqual(summary.operation, .modify)
        XCTAssertEqual(summary.payloadKind, .file)
        XCTAssertEqual(summary.previousDigest, previousDigest)
        XCTAssertEqual(summary.byteCount, original.count)
        XCTAssertEqual(summary.digest, "8b37c60caf7a515a32a7dc6c10a9470c7dae3df03b719dc686e35feff45a42f5")
        let revealed = try harness.coordinator.reveal(requestID: approval.requestID)
        XCTAssertEqual(revealed.bytes, original)
        XCTAssertEqual(revealed.digest, summary.digest)

        _ = try harness.coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )
        var committed: BrokerFrozenFile?
        try harness.coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        ) { committed = $0 }
        XCTAssertEqual(committed?.bytes, original)
        XCTAssertNotEqual(committed?.bytes, replacement)
    }

    func testDigestSwapAndReplayCannotReuseApproval() throws {
        let harness = try makeHarness()
        let bytes = Data("approved-payload".utf8)
        let upload = try begin(harness, operationID: "digest-bound", expectedByteCount: bytes.count)
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try harness.coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)
        let summary = try harness.coordinator.summary(requestID: approval.requestID)
        let swapped = Data("swapped-payload!".utf8)
        let retry = try begin(harness, operationID: "digest-bound", expectedByteCount: swapped.count)
        try harness.coordinator.append(
            uploadID: retry.uploadID,
            capability: retry.capability,
            offset: 0,
            bytes: swapped
        )
        XCTAssertThrowsError(
            try harness.coordinator.freeze(uploadID: retry.uploadID, capability: retry.capability)
        ) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .payloadMismatch)
        }
        _ = try harness.coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )

        XCTAssertThrowsError(
            try harness.coordinator.commit(
                requestID: approval.requestID,
                capability: approval.capability,
                expectedDigest: String(repeating: "0", count: 64),
                consume: { _ in }
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .digestMismatch)
        }
        var commitCount = 0
        XCTAssertThrowsError(
            try harness.coordinator.commit(
                requestID: approval.requestID,
                capability: approval.capability,
                expectedDigest: summary.digest,
                consume: { _ in throw CommitFixtureError.failed }
            )
        ) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .outcomeUnknown)
        }
        XCTAssertEqual(
            try harness.approvals.status(
                requestID: approval.requestID,
                capability: approval.capability
            ),
            .approved
        )
        try harness.coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        ) { _ in
            XCTAssertEqual(
                harness.approvals.cancelPending(credentialID: "credential-id"),
                0,
                "the standard mutation callback must not deadlock or cancel its reservation"
            )
            commitCount += 1
        }
        XCTAssertThrowsError(
            try harness.coordinator.commit(
                requestID: approval.requestID,
                capability: approval.capability,
                expectedDigest: summary.digest,
                consume: { _ in commitCount += 1 }
            )
        )
        XCTAssertEqual(commitCount, 1)
    }

    func testActiveRevealRequiresAuthenticationAndDoesNotApprove() throws {
        let revealAllowed = LockedFlag(false)
        let harness = try makeHarness(authenticateReveal: { revealAllowed.value })
        let bytes = Data("inspect-me".utf8)
        let upload = try begin(harness, operationID: "reveal", expectedByteCount: bytes.count)
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try harness.coordinator.freeze(uploadID: upload.uploadID, capability: upload.capability)

        XCTAssertThrowsError(try harness.coordinator.reveal(requestID: approval.requestID)) { error in
            XCTAssertEqual(error as? BrokerFileWriteError, .authenticationFailed)
        }
        revealAllowed.value = true
        let revealed = try harness.coordinator.reveal(requestID: approval.requestID)
        XCTAssertEqual(revealed.bytes, bytes)
        XCTAssertEqual(
            try harness.approvals.status(
                requestID: approval.requestID,
                capability: approval.capability
            ),
            .pending
        )
        XCTAssertThrowsError(
            try harness.coordinator.commit(
                requestID: approval.requestID,
                capability: approval.capability,
                expectedDigest: revealed.digest,
                consume: { _ in }
            )
        )
    }

    func testFailedCommitDuringPauseCancelsApprovalInsteadOfAllowingRetry() throws {
        let harness = try makeHarness()
        let bytes = Data("pause-race".utf8)
        let upload = try begin(harness, operationID: "pause-race", expectedByteCount: bytes.count)
        try harness.coordinator.append(
            uploadID: upload.uploadID,
            capability: upload.capability,
            offset: 0,
            bytes: bytes
        )
        let approval = try harness.coordinator.freeze(
            uploadID: upload.uploadID,
            capability: upload.capability
        )
        let summary = try harness.coordinator.summary(requestID: approval.requestID)
        _ = try harness.coordinator.decide(
            requestID: approval.requestID,
            capability: approval.capability,
            decision: .once
        )

        XCTAssertThrowsError(try harness.coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest
        ) { _ in
            harness.approvals.pauseAndCancelAll()
            throw CommitFixtureError.failed
        })
        XCTAssertEqual(
            try harness.approvals.status(
                requestID: approval.requestID,
                capability: approval.capability
            ),
            .cancelled
        )
        harness.approvals.resume()
        XCTAssertThrowsError(try harness.coordinator.commit(
            requestID: approval.requestID,
            capability: approval.capability,
            expectedDigest: summary.digest,
            consume: { _ in }
        ))
    }

    func testVersionedBrokerExposesOnlyUploadChunkAndFreeze() throws {
        let harness = try makeHarness()
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            fileWrite: { try harness.coordinator.handle($0) }
        )
        let socketPath = "/tmp/askkey-225-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        addTeardownBlock {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let client = BrokerSocketClient(socketPath: socketPath)
        let beginResponse = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .begin(.init(
                operationID: "protocol-upload",
                credentialID: "credential-id",
                targetID: "credential-id",
                operation: .modify,
                originalFilename: "AuthKey.p8",
                expectedByteCount: 3
            ))
        ))
        guard case .success(.fileWrite(.upload(let upload))) = beginResponse else {
            return XCTFail("expected capability-bound upload ticket, got \(beginResponse)")
        }
        let chunkResponse = try client.send(.init(
                version: BrokerProtocolVersion.current,
                method: "credential.file.write",
                fileWrite: .append(.init(
                    uploadID: upload.uploadID,
                    capability: upload.capability,
                    offset: 0,
                    bytes: Data("abc".utf8)
                ))
            ))
        XCTAssertEqual(
            chunkResponse,
            .success(.fileWrite(.chunkAccepted(nextOffset: 3)))
        )
        XCTAssertFalse(try JSONEncoder().encode(chunkResponse).contains(Data("abc".utf8)))
        let secretFailure = Data("must-not-echo".utf8)
        let failureResponse = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .append(.init(
                uploadID: upload.uploadID,
                capability: upload.capability,
                offset: 99,
                bytes: secretFailure
            ))
        ))
        XCTAssertEqual(failureResponse, .failure(.invalidRequest))
        XCTAssertFalse(try JSONEncoder().encode(failureResponse).contains(secretFailure))
        let freezeResponse = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .freeze(.init(uploadID: upload.uploadID, capability: upload.capability))
        ))
        guard case .success(.fileWrite(.approval(let approval))) = freezeResponse else {
            return XCTFail("expected approval ticket, got \(freezeResponse)")
        }
        XCTAssertEqual(approval.state, .pending)
        let retryResponse = try client.send(.init(
            version: BrokerProtocolVersion.current,
            method: "credential.file.write",
            fileWrite: .freeze(.init(uploadID: upload.uploadID, capability: upload.capability))
        ))
        guard case .success(.fileWrite(.approval(let retry))) = retryResponse else {
            return XCTFail("expected retry ticket, got \(retryResponse)")
        }
        XCTAssertEqual(retry.requestID, approval.requestID)
        XCTAssertEqual(retry.capability, approval.capability)
        XCTAssertEqual(retry.retryCount, 1)

        for forbidden in ["credential.file.reveal", "credential.file.approve", "credential.file.commit"] {
            XCTAssertEqual(
                try client.send(.init(version: BrokerProtocolVersion.current, method: forbidden)),
                .failure(.methodNotAllowed)
            )
        }
    }

    private func begin(
        _ harness: Harness,
        operationID: String,
        expectedByteCount: Int
    ) throws -> BrokerFileUploadTicket {
        try harness.coordinator.begin(
            operationID: operationID,
            credentialID: "credential-id",
            targetID: "credential-id",
            operation: .modify,
            originalFilename: "AuthKey.p8",
            expectedByteCount: expectedByteCount
        )
    }

    private func makeCoordinator(stagingDirectory: URL) throws -> BrokerFileWriteCoordinator {
        try BrokerFileWriteCoordinator(
            stagingDirectory: stagingDirectory,
            approvals: BrokerApprovalStateMachine(authenticate: { _ in true }),
            authenticateReveal: { true },
            commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in
                try BrokerApprovalStateMachine(authenticate: { _ in true })
                    .submit(request, trustedCredentialDeadline: .none)
            },
            normalizeCreateTarget: { $0 }
        )
    }

    private func makeHarness(
        authenticateReveal: @escaping @Sendable () -> Bool = { true },
        commitFrozenFile: @escaping @Sendable (BrokerFrozenFile) throws -> Void = { _ in },
        submitFrozenApproval: (@Sendable (
            String, String?, BrokerApprovalOperationRequest
        ) throws -> BrokerApprovalTicket)? = nil,
        normalizeCreateTarget: @escaping @Sendable (String) throws -> String = { $0 },
        resolvePreviousDigest: @escaping @Sendable (String) throws -> String? = { _ in nil },
        uploadTTL: TimeInterval = 5 * 60,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyFileWriteTests-\(UUID().uuidString)", isDirectory: true)
        let approvals = BrokerApprovalStateMachine(authenticate: { _ in true })
        let submit = submitFrozenApproval ?? { credentialID, expectedDigest, request in
            let currentDigest = request.operation == .modify
                ? try resolvePreviousDigest(credentialID)
                : nil
            guard currentDigest == expectedDigest else {
                throw BrokerFileWriteError.targetChanged
            }
            return try approvals.submit(request, trustedCredentialDeadline: .none)
        }
        let coordinator = try BrokerFileWriteCoordinator(
            stagingDirectory: directory,
            approvals: approvals,
            authenticateReveal: authenticateReveal,
            commitFrozenFile: commitFrozenFile,
            submitFrozenApproval: submit,
            normalizeCreateTarget: normalizeCreateTarget,
            resolvePreviousDigest: resolvePreviousDigest,
            uploadTTL: uploadTTL,
            clock: clock
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return Harness(coordinator: coordinator, approvals: approvals, directory: directory)
    }
}

private enum CommitFixtureError: Error { case failed }

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var now: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) { storedValue = value }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); storedValue = newValue; lock.unlock() }
    }
}

private final class LockedDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) { storedValue = value }

    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); storedValue = newValue; lock.unlock() }
    }
}

private struct Harness {
    let coordinator: BrokerFileWriteCoordinator
    let approvals: BrokerApprovalStateMachine
    let directory: URL
}
