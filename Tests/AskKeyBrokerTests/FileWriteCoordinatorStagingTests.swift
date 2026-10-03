import Foundation
import XCTest
@testable import AskKeyBroker

final class FileWriteCoordinatorStagingTests: FileWriteCoordinatorTestCase {
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
}
