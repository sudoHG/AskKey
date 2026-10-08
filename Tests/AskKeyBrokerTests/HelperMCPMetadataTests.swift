import XCTest
@testable import AskKeyBroker

final class HelperMCPMetadataTests: HelperMCPTestCase {
    func testSchemasOfferOptionalMetadataAndKeepTextOnlyToolsUnchanged() throws {
        let (process, input, output) = try startMCPHelper(socketPath: "/tmp/ak-meta-schema-\(UUID().uuidString.prefix(8)).sock")
        let response = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        func schema(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(tools.first { $0["name"] as? String == name }?["inputSchema"] as? [String: Any])
        }
        let create = try schema("create_credential")
        let modify = try schema("modify_credential")
        XCTAssertEqual(create["required"] as? [String], ["name", "operation_id", "components"])
        XCTAssertEqual(modify["required"] as? [String], ["name", "operation_id"])
        XCTAssertEqual((modify["anyOf"] as? [[String: [String]]])?.flatMap { $0["required"] ?? [] },
            ["changes", "usage_instructions", "group"])
        let properties = try XCTUnwrap(modify["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["group"]?["type"] as? [String], ["string", "null"])
        let guidance = try XCTUnwrap(properties["usage_instructions"]?["description"] as? String)
        XCTAssertTrue(guidance.contains("full instructions"))
        XCTAssertTrue(guidance.contains("separate system authentication"))
        for name in ["create_text_credential", "modify_text_credential"] {
            let properties = try XCTUnwrap(try schema(name)["properties"] as? [String: Any])
            XCTAssertNil(properties["usage_instructions"])
            XCTAssertNil(properties["group"])
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testHelperForwardsMetadataCreateModifyClearAndIdenticalCommit() throws {
        let fixture = try startFixture()
        var create: [String: Any] = ["operation_id": "create", "name": "Service", "components": [
            ["name": "token", "text": "synthetic-token", "delivery": ["type": "none"]]],
            "usage_instructions": "Use staging only", "group": "Staging"]
        let response = try call("create_credential", create, fixture: fixture)
        let broker = try JSONDecoder().decode(BrokerResponse.self, from: Data(mcpText(response).utf8))
        guard case .success(.textWriteRequest(.submitted(let ticket))) = broker else { return XCTFail("Expected submitted write") }
        XCTAssertEqual(fixture.recorder.submissions.last?.action, .createBundle(name: "Service", components: [
            .init(name: "token", value: .text("synthetic-token"), delivery: .none)], usageInstructions: "Use staging only", group: "Staging"))
        create["request_id"] = ticket.requestID
        create["capability"] = ticket.capability
        _ = try call("create_credential", create, fixture: fixture)
        XCTAssertEqual(fixture.recorder.commits, fixture.recorder.submissions)
        let cases: [([String: Any], AgentTextWriteAction)] = [
            (["usage_instructions": "Updated"], .modifyBundle(name: "Service", usageInstructions: "Updated")),
            (["group": "Other"], .modifyBundle(name: "Service", group: .named("Other"))),
            (["usage_instructions": "", "group": NSNull()], .modifyBundle(name: "Service", usageInstructions: "", group: .ungrouped)),
            (["changes": [["remove": "extra"]], "usage_instructions": "Both", "group": "Other"],
             .modifyBundle(name: "Service", changes: [.remove("extra")], usageInstructions: "Both", group: .named("Other")))
        ]
        for (fields, expected) in cases {
            var arguments = fields
            arguments["name"] = "Service"
            arguments["operation_id"] = UUID().uuidString
            _ = try call("modify_credential", arguments, fixture: fixture)
            XCTAssertEqual(fixture.recorder.submissions.last?.action, expected)
        }
        try fixture.input.fileHandleForWriting.close()
        fixture.process.waitUntilExit()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }

    func testMalformedMetadataAndEmptyModificationNeverReachBroker() throws {
        let fixture = try startFixture()
        for fields: [String: Any] in [[:], ["usage_instructions": NSNull()], ["usage_instructions": 42],
            ["group": 42], ["changes": NSNull()], ["changes": []], ["changes": "invalid"],
            ["usage_instructions": "valid", "group": false]] {
            var arguments = fields
            arguments["name"] = "Service"
            arguments["operation_id"] = UUID().uuidString
            let response = try call("modify_credential", arguments, fixture: fixture)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        for field in ["usage_instructions", "group"] {
            let response = try call("create_credential", ["name": "Service", "operation_id": UUID().uuidString,
                "components": [["name": "token", "text": "synthetic", "delivery": ["type": "none"]]],
                field: NSNull()], fixture: fixture)
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        XCTAssertTrue(fixture.recorder.submissions.isEmpty)
        try fixture.input.fileHandleForWriting.close()
        fixture.process.waitUntilExit()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }

    private struct Fixture {
        let recorder: ComponentWriteRecorder
        let process: Process
        let input: Pipe
        let output: Pipe
    }

    private func startFixture() throws -> Fixture {
        let directory = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-meta-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let approvals = BrokerApprovalStateMachine()
        let coordinator = try BrokerFileWriteCoordinator(stagingDirectory: directory.appendingPathComponent("uploads"),
            approvals: approvals, authenticateReveal: { false }, commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in try approvals.submit(request) }, normalizeCreateTarget: { $0 })
        let recorder = ComponentWriteRecorder(coordinator: coordinator)
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in try recorder.submit(request) },
            commitTextWrite: { try recorder.commit($0, requestID: $1, capability: $2) }))
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        return Fixture(recorder: recorder, process: process, input: input, output: output)
    }

    private func call(_ name: String, _ arguments: [String: Any], fixture: Fixture) throws -> [String: Any] {
        try exchangeMCP(input: fixture.input, output: fixture.output, object: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]])
    }
}
