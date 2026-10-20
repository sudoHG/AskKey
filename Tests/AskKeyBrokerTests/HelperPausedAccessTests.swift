import Foundation
import XCTest
@testable import AskKeyBroker

final class HelperPausedMCPTests: HelperMCPTestCase {
    func testPausedAccessKeepsErrorCodeAndAddsOnlyTheUserRecoveryStep() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ak-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("b.sock").path
        let replied = expectation(description: "synthetic broker replied")
        try startResponseServer(
            socketPath: socketPath, responses: [.failure(.agentAccessPaused), .failure(.invalidRequest)], replied: replied
        )
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        let failure = try callMCPTool(processInput: input, processOutput: output, id: 1, name: "list_credentials")
        XCTAssertEqual((failure["result"] as? [String: Any])?["isError"] as? Bool, true)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mcpText(failure).utf8)) as? [String: String]
        )
        XCTAssertEqual(payload, [
            "status": "request_rejected",
            "brokerCode": "agent_access_paused",
            "next_step": "Ask the user to choose Resume Agent Access in Ask Key.",
        ])
        let unrelated = try callMCPTool(processInput: input, processOutput: output, id: 2, name: "list_credentials")
        let unrelatedPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mcpText(unrelated).utf8)) as? [String: String]
        )
        XCTAssertNil(unrelatedPayload["next_step"])
        wait(for: [replied], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

final class HelperPausedCLITests: HelperApprovalWaitTestCase {
    func testPausedRunKeepsFailureExitAndAddsRecoveryWithoutRunningTheTarget() throws {
        let directory = try makeTemporaryDirectory(prefix: "ak-paused")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("b.sock").path
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { _ in [] }, requestStatus: { _, _ in nil },
            textRun: { _, _, _ in throw BrokerProviderError.agentAccessPaused }
        ))
        try server.start()
        defer { server.stop() }
        for waitArguments in [[], ["--wait-for-approval"]] {
            let result = try runHelper(
                socketPath: socketPath,
                arguments: ["run", "--credential", "synthetic"] + waitArguments + ["--", "/usr/bin/printf", "must-not-run"],
                timeout: 5
            )
            XCTAssertFalse(result.timedOut)
            XCTAssertEqual(result.status, 1)
            XCTAssertTrue(result.stdoutText.isEmpty)
            XCTAssertTrue(result.stderrText.contains("agent_access_paused"))
            XCTAssertTrue(result.stderrText.contains("Ask the user to choose Resume Agent Access in Ask Key."))
        }
    }
}
