import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentTextWriteBrokerSocketTests: AgentTextWriteTestSupport {
    func testBrokerSocketForwardsWriteWithoutEchoingValue() throws {
        let harness = try makeHarness(authenticate: { _ in true })
        let socketPath = "/tmp/askkey-write-\(UUID().uuidString.prefix(8)).sock"
        let handler = BrokerRequestHandler(
            catalog: { _ in [] },
            requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in try harness.vault.requestAgentTextWrite(request) },
            commitTextWrite: { request, requestID, capability in
                try harness.vault.commitAgentTextWrite(
                    request,
                    requestID: requestID,
                    capability: capability
                )
            },
            cancelTextWrite: { operationID, requestID, capability in
                try harness.vault.cancelAgentTextWrite(
                    operationID: operationID,
                    requestID: requestID,
                    capability: capability
                )
            }
        )
        let server = BrokerSocketServer(socketPath: socketPath, handler: handler)
        try server.start()
        defer { server.stop() }
        let write = AgentTextWriteRequest(
            operationID: "wire-create",
            action: .create(name: "Wire", value: "wire-secret-value")
        )
        let response = try BrokerSocketClient(socketPath: socketPath).send(
            .init(version: 1, method: "credential.write.request", textWrite: write)
        )
        let responseJSON = try encoded(response)
        XCTAssertFalse(responseJSON.contains("wire-secret-value"))
        guard case let .success(.textWriteRequest(.submitted(submission))) = response else {
            return XCTFail("Expected write submission, got \(response)")
        }
        _ = try harness.vault.approvalRequests.decide(
            requestID: submission.requestID,
            capability: submission.capability,
            decision: .once
        )
        let committed = try BrokerSocketClient(socketPath: socketPath).send(
            .init(
                version: 1,
                method: "credential.write.commit",
                requestID: submission.requestID,
                capability: submission.capability,
                textWrite: write
            )
        )
        XCTAssertFalse(try encoded(committed).contains("wire-secret-value"))
        guard case let .success(.textWriteResult(result)) = committed else {
            return XCTFail("Expected completed write, got \(committed)")
        }
        XCTAssertEqual(result.operationID, "wire-create")
        XCTAssertEqual(result.state, .completed)
        let replay = try BrokerSocketClient(socketPath: socketPath).send(
            .init(version: 1, method: "credential.write.request", textWrite: write)
        )
        guard case let .success(.textWriteRequest(.completed(replayed))) = replay else {
            return XCTFail("Expected completed replay, got \(replay)")
        }
        XCTAssertEqual(replayed, result)
        XCTAssertFalse(try encoded(replay).contains("wire-secret-value"))
    }
}
