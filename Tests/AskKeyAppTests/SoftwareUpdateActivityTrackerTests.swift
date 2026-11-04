import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker

final class SoftwareUpdateActivityTrackerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private struct SyntheticFailure: Error {}

    private let clock = Clock()
    private lazy var tracker = AgentActivityTracker(clock: { [clock] in clock.now })

    private func upload(_ id: String) -> BrokerFileWritePayload {
        // The ticket has no public memberwise initializer; decode it like the helper does.
        let json = Data(#"{"uploadID":"\#(id)","capability":"capability-\#(id)"}"#.utf8)
        return .upload(try! JSONDecoder().decode(BrokerFileUploadTicket.self, from: json))
    }

    private func freeze(_ id: String) -> BrokerFileWriteFreezeRequest {
        BrokerFileWriteFreezeRequest(uploadID: id, capability: "capability-\(id)")
    }

    private var begin: BrokerFileWriteRequest {
        .begin(BrokerFileWriteBeginRequest(
            operationID: "operation", credentialID: "credential", targetID: "credential",
            operation: .modify, originalFilename: "synthetic.txt", expectedByteCount: 4
        ))
    }

    private var beginComponent: BrokerFileWriteRequest {
        .beginComponent(BrokerComponentUploadBeginRequest(
            operationID: "operation", originalFilename: "synthetic.txt", expectedByteCount: 4
        ))
    }

    func testRunningCallsAreCountedUntilTheyEnd() {
        XCTAssertEqual(tracker.runningCallCount, 0)
        tracker.beginCall()
        tracker.beginCall()
        XCTAssertEqual(tracker.runningCallCount, 2)
        tracker.endCall()
        tracker.endCall()
        tracker.endCall()
        XCTAssertEqual(tracker.runningCallCount, 0, "an extra end never goes negative")
    }

    func testFileWriteCallCountsWhileRunningAndAfterFailure() {
        let observed = tracker.fileWrite(begin) { () -> BrokerFileWritePayload in
            XCTAssertEqual(tracker.runningCallCount, 1)
            return upload("a")
        }
        XCTAssertEqual(observed, upload("a"))
        XCTAssertEqual(tracker.runningCallCount, 0)

        XCTAssertThrowsError(try tracker.fileWrite(begin) { throw SyntheticFailure() })
        XCTAssertEqual(tracker.runningCallCount, 0)
        XCTAssertEqual(tracker.openUploadCount, 1, "a failed begin opens nothing")
    }

    func testUploadStaysOpenUntilFrozenOrCancelled() {
        _ = tracker.fileWrite(begin) { upload("file") }
        _ = tracker.fileWrite(begin) { upload("cancelled") }
        XCTAssertEqual(tracker.openUploadCount, 2)

        _ = tracker.fileWrite(.append(BrokerFileWriteChunkRequest(
            uploadID: "file", capability: "capability-file", offset: 0, bytes: Data("abcd".utf8)
        ))) { .chunkAccepted(nextOffset: 4) }
        XCTAssertEqual(tracker.openUploadCount, 2)

        _ = tracker.fileWrite(.cancelUpload(freeze("cancelled"))) { .uploadCancelled }
        XCTAssertEqual(tracker.openUploadCount, 1)

        let ticket = BrokerApprovalTicket(requestID: "request", capability: "approval", state: .pending, retryCount: 0)
        _ = tracker.fileWrite(.freeze(freeze("file"))) { .approval(ticket) }
        XCTAssertEqual(tracker.openUploadCount, 0, "the frozen file now waits as an approval")
    }

    func testUploadExpiresAfterTheBrokerLifetimeAndEachCallRenewsIt() {
        _ = tracker.fileWrite(beginComponent) { upload("component") }
        clock.now += AgentActivityTracker.uploadLifetime - 1
        _ = tracker.fileWrite(.freezeComponent(freeze("component"))) {
            .componentFrozen(BrokerComponentFileReference(
                uploadID: "component", capability: "capability-component", digest: "digest"
            ))
        }
        clock.now += AgentActivityTracker.uploadLifetime - 1
        XCTAssertEqual(tracker.openUploadCount, 1, "the frozen component waits for its write request")

        clock.now += 1
        XCTAssertEqual(tracker.openUploadCount, 0)
    }

    func testCallsForUnknownUploadsOpenNothing() {
        _ = tracker.fileWrite(.append(BrokerFileWriteChunkRequest(
            uploadID: "unknown", capability: "capability", offset: 0, bytes: Data()
        ))) { .chunkAccepted(nextOffset: 0) }
        _ = tracker.fileWrite(.freezeComponent(freeze("unknown"))) {
            .componentFrozen(BrokerComponentFileReference(uploadID: "unknown", capability: "capability", digest: "digest"))
        }
        XCTAssertEqual(tracker.openUploadCount, 0)
    }

    func testApprovalIsCountedWhilePendingAndApprovedThenForgotten() {
        let request = BrokerApprovalOperationRequest(
            operationID: "operation", credentialID: "credential", targetID: "credential",
            operation: .read, payloadDigest: "digest"
        )
        let pending = BrokerPendingApproval(requestID: "request", capability: "capability", request: request)
        var state: BrokerRequestState? = .pending
        var queried: [String] = []
        let status: (String, String) -> BrokerRequestState? = { requestID, capability in
            queried.append("\(requestID)/\(capability)")
            return state
        }

        var counts = tracker.refreshApprovals(pending: [pending], status: status)
        XCTAssertEqual(counts.pending, 1)
        XCTAssertEqual(counts.approved, 0)
        XCTAssertEqual(queried, ["request/capability"])

        // Approved requests leave the pending list but still postpone a relaunch.
        state = .approved
        counts = tracker.refreshApprovals(pending: [], status: status)
        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(counts.approved, 1)

        state = .consumed
        counts = tracker.refreshApprovals(pending: [], status: status)
        XCTAssertEqual(counts.pending + counts.approved, 0)

        state = .approved
        queried = []
        counts = tracker.refreshApprovals(pending: [], status: status)
        XCTAssertEqual(counts.approved, 0, "a finished request is forgotten")
        XCTAssertEqual(queried, [])
    }

    func testUnknownOrEndedApprovalsAreForgotten() {
        let request = BrokerApprovalOperationRequest(
            operationID: "operation", credentialID: "credential", targetID: "credential",
            operation: .read, payloadDigest: "digest"
        )
        let ended: [BrokerRequestState?] = [nil, .denied, .cancelled, .expired, .completed, .consumed, .outcomeUnknown]
        for state in ended {
            let pending = BrokerPendingApproval(requestID: "request", capability: "capability", request: request)
            let counts = tracker.refreshApprovals(pending: [pending]) { _, _ in state }
            XCTAssertEqual(counts.pending + counts.approved, 0, "\(String(describing: state))")
            XCTAssertEqual(tracker.refreshApprovals(pending: []) { _, _ in .pending }.pending, 0)
        }
    }
}
