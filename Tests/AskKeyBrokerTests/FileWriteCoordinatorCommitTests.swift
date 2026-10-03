import Foundation
import XCTest
@testable import AskKeyBroker

final class FileWriteCoordinatorCommitTests: FileWriteCoordinatorTestCase {
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
}
