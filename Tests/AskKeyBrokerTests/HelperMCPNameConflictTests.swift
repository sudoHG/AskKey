import XCTest
@testable import AskKeyBroker

final class HelperMCPNameConflictTests: HelperMCPTestCase {
    func testVisibleNameConflictOffersActionableMCPError() throws {
        let responses = try createFailures(code: .credentialNameConflict)
        for response in responses {
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
            let payload = try errorPayload(response)
            XCTAssertEqual(payload["status"], "request_rejected")
            XCTAssertEqual(payload["brokerCode"], "credential_name_conflict")
            XCTAssertEqual(payload["next_step"], "A credential with this name already exists. Use list_credentials to find it, then choose a different name or use modify_credential to update it.")
            XCTAssertEqual(payload.count, 3)
        }
    }

    func testGenericMCPErrorRetainsExactPayloadWithoutNameConflictHint() throws {
        let responses = try createFailures(code: .internalError)
        for response in responses {
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
            XCTAssertEqual(try mcpText(response), #"{"brokerCode":"internal_error","status":"request_rejected"}"#)
            XCTAssertEqual(try errorPayload(response), ["brokerCode": "internal_error", "status": "request_rejected"])
        }
    }

    private func errorPayload(_ response: [String: Any]) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcpText(response).utf8)) as? [String: String])
    }

    private func createFailures(code: BrokerErrorCode) throws -> [[String: Any]] {
        let directory = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-duplicate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let providerError: Error = code == .credentialNameConflict
            ? BrokerProviderError.credentialNameConflict : CocoaError(.fileReadUnknown)
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil },
                submitTextWrite: { _, _ in throw providerError }))
        try server.start()
        defer { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        var responses: [[String: Any]] = []
        for tool in ["create_credential", "create_text_credential"] {
            let arguments: [String: Any] = ["name": "Synthetic", "operation_id": UUID().uuidString,
                "value": "synthetic-value", "components": [
                    ["name": "token", "text": "synthetic-value", "delivery": ["type": "none"]]
                ]]
            responses.append(try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": responses.count, "method": "tools/call",
                "params": ["name": tool, "arguments": arguments]
            ]))
        }
        return responses
    }
}
