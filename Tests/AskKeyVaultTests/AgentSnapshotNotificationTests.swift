import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

@MainActor
final class AgentSnapshotNotificationTests: XCTestCase {
    func testBackgroundCommitReleasesGateBeforeMainQueueObserverUnlocks() async throws {
        let library = try AgentAccessPolicyLibrary()
        defer { try? library.close() }
        let vault = library.vault
        vault.approvalRequests.configureAuthentication { _ in true }
        let request = AgentTextWriteRequest(operationID: "notification-commit", action: .create(name: "SYNTHETIC", value: "synthetic-value"))
        guard case let .submitted(submission) = try vault.requestAgentTextWrite(request) else {
            return XCTFail("Expected pending creation")
        }
        _ = try vault.approvalRequests.decide(requestID: submission.requestID,
                                             capability: submission.capability, decision: .once)
        let observed = expectation(description: "Main-queue observer reopened the same Vault")
        let completed = expectation(description: "Background agent commit returned")
        let operation = SnapshotCommitOperation(vault)
        let observer = NotificationCenter.default.addObserver(
            forName: .askKeyCredentialSnapshotDidChange, object: nil, queue: .main
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            do {
                // Fail without blocking forever if an old implementation posts
                // while it still owns the exclusive gate.
                guard try !operation.vault.isAgentAccessPaused() else {
                    XCTFail("Snapshot notification was posted while the exclusive gate was held")
                    observed.fulfill()
                    return
                }
                try operation.vault.unlock()
            } catch { XCTFail("Main-thread unlock failed: \(error)") }
            observed.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        DispatchQueue.global().async {
            do {
                _ = try operation.vault.commitAgentTextWrite(
                    request, requestID: submission.requestID, capability: submission.capability
                )
            } catch { XCTFail("Background commit failed: \(error)") }
            completed.fulfill()
        }
        await fulfillment(of: [observed, completed], timeout: 5)
        XCTAssertFalse(try vault.isAgentAccessPaused())
        XCTAssertEqual(try vault.brokerCredentialCatalog().map(\.name), ["SYNTHETIC"])
    }
}

private final class SnapshotCommitOperation: @unchecked Sendable {
    let vault: Vault
    init(_ vault: Vault) { self.vault = vault }
}
