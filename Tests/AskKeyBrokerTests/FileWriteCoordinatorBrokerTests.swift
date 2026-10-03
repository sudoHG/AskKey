import Foundation
import XCTest
@testable import AskKeyBroker

final class FileWriteCoordinatorBrokerTests: FileWriteCoordinatorTestCase {
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
}
