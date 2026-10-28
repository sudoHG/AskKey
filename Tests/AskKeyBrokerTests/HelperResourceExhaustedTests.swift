import XCTest
@testable import AskKeyBroker

final class HelperResourceExhaustedTests: HelperMCPTestCase {
    func testCommitAndCapacityFailuresOfferBoundedRecoveryWithoutDisclosingMaterial() throws {
        let directory = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-size-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("b.sock").path
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { _ in throw BrokerProviderError.resourceExhausted }, requestStatus: { _, _ in nil },
            commitTextWrite: { _, _, _ in throw BrokerProviderError.resourceExhausted }
        ))
        try server.start()
        defer { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let arguments: [String: Any] = ["name": "Synthetic", "operation_id": "synthetic-size",
            "request_id": "synthetic-request", "capability": "synthetic-capability", "changes": [
                ["upsert": ["name": "Token", "text": "synthetic-private-value", "delivery": ["type": "none"]]]
            ]]
        for (tool, payload) in [("modify_credential", arguments), ("list_credentials", [:])] {
            let response = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": tool, "method": "tools/call",
                "params": ["name": tool, "arguments": payload]])
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
            let text = try mcpText(response)
            let error = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
            XCTAssertEqual(error["status"], "request_rejected")
            XCTAssertEqual(error["brokerCode"], "resource_exhausted")
            let next = try XCTUnwrap(error["next_step"])
            XCTAssertTrue(next.contains("5 MiB"))
            XCTAssertTrue(next.contains("the change was not saved; send a smaller change"))
            XCTAssertTrue(next.contains("untouched stored values"))
            XCTAssertTrue(next.contains("wait for pending requests to finish"))
            XCTAssertTrue(next.contains("Do not blindly retry the same write"))
            XCTAssertFalse(text.contains("synthetic-private-value"))
            XCTAssertFalse(text.contains("synthetic-capability"))
        }
    }

    func testInitializeAndModifyDescriptionExplainCommitTimeSizeLimit() throws {
        let (process, input, output) = try startMCPHelper(socketPath:
            FileManager.default.temporaryDirectory.appendingPathComponent("ak-size-\(UUID().uuidString.prefix(8)).sock").path)
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        let initialized = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let instructions = try XCTUnwrap((initialized["result"] as? [String: Any])?["instructions"] as? String)
        let listed = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let description = try XCTUnwrap(tools.first { $0["name"] as? String == "modify_credential" }?["description"] as? String)
        for guidance in [instructions, description] {
            XCTAssertTrue(guidance.contains("untouched stored component values"))
            XCTAssertTrue(guidance.contains("5 MiB"))
            XCTAssertTrue(guidance.contains("checked again at commit"))
            XCTAssertTrue(guidance.contains("not saved and returns resource_exhausted"))
            XCTAssertTrue(guidance.contains("Send a smaller change"))
        }
    }
}
