import XCTest
@testable import AskKeyBroker

final class HelperMCPOrganizationTests: HelperMCPTestCase {
    func testSchemaAdvertisesOrderedBoundedOrganizationAndExplicitApprovalResume() throws {
        let fixture = try startFixture()
        let response = try exchangeMCP(input: fixture.input, output: fixture.output, object: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]])
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let definition = try XCTUnwrap(tools.first { $0["name"] as? String == "organize_credentials" })
        let schema = try XCTUnwrap(definition["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(schema["required"] as? [String], ["operation_id", "operations"])
        XCTAssertEqual(properties["operations"]?["minItems"] as? Int, 1)
        XCTAssertEqual(properties["operations"]?["maxItems"] as? Int, 64)
        let description = try XCTUnwrap(definition["description"] as? String)
        XCTAssertTrue(description.contains("one system authentication"))
        XCTAssertTrue(description.contains("timed read allowances never authorize"))
        XCTAssertTrue(description.contains("request_id and capability"))
        try stop(fixture)
    }

    func testHelperForwardsOrderedOperationsNullGroupAndExactCommitWithoutMemberLeak() throws {
        let fixture = try startFixture()
        var arguments: [String: Any] = ["operation_id": "batch", "operations": [
            ["create_group": "New"], ["move": ["credential": "API", "group": "New"]],
            ["rename_group": ["from": "Old", "to": "Renamed"]], ["delete_group": "Renamed"],
            ["move": ["credential": "API", "group": NSNull()]]]]
        let reply = try call("organize_credentials", arguments, fixture: fixture)
        let broker = try JSONDecoder().decode(BrokerResponse.self, from: Data(mcpText(reply).utf8))
        guard case .success(.textWriteRequest(.submitted(let ticket))) = broker else { return XCTFail("Expected one pending batch") }
        XCTAssertEqual(fixture.recorder.submissions.first?.action, .organize([.createGroup("New"),
            .move(credential: "API", group: "New"), .renameGroup(from: "Old", to: "Renamed"), .deleteGroup("Renamed"),
            .move(credential: "API", group: nil)]))
        arguments["request_id"] = ticket.requestID
        arguments["capability"] = ticket.capability
        let committed = try call("organize_credentials", arguments, fixture: fixture)
        XCTAssertEqual(try JSONDecoder().decode(BrokerResponse.self, from: Data(mcpText(committed).utf8)),
            .success(.organizationWriteResult(operationID: "batch")))
        XCTAssertEqual(fixture.recorder.commits, fixture.recorder.submissions)
        XCTAssertFalse(try mcpText(committed).contains("credentialID"))
        let catalog = try call("list_credentials", [:], fixture: fixture)
        let catalogBody = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcpText(catalog).utf8)) as? [String: Any])
        XCTAssertEqual(catalogBody["groups"] as? [String], ["Empty", "Visible"])
        XCTAssertEqual((catalogBody["credentials"] as? [[String: Any]])?.count, 0)
        try stop(fixture)
    }

    func testMalformedUnsupportedAndOversizedOperationsNeverReachBroker() throws {
        let fixture = try startFixture()
        for raw: Any in [[], [["move": ["credential": "API"]]], [["move": ["credential": "API", "group": 1]]],
            [["move": ["credential": "API", "group": NSNull(), "permission": "Allow"]]],
            [["create_group": "New", "delete_group": "Old"]], [["rename_group": ["from": "Old", "to": "New", "extra": true]]],
            [["delete_credential": "API"]], [["create_group": NSNull()]],
            Array(repeating: ["create_group": "New"], count: 65)] {
            let reply = try call("organize_credentials", ["operation_id": "batch", "operations": raw], fixture: fixture)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        XCTAssertTrue(fixture.recorder.submissions.isEmpty)
        _ = try call("organize_credentials", ["operation_id": "valid", "operations": Array(repeating: ["create_group": "New"], count: 64)], fixture: fixture)
        XCTAssertEqual(fixture.recorder.submissions.count, 1)
        try stop(fixture)
    }

    private struct Fixture {
        let recorder: ComponentWriteRecorder
        let process: Process
        let input: Pipe
        let output: Pipe
    }

    private func startFixture() throws -> Fixture {
        let directory = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-org-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let machine = BrokerApprovalStateMachine()
        let coordinator = try BrokerFileWriteCoordinator(stagingDirectory: directory.appendingPathComponent("uploads"),
            approvals: machine, authenticateReveal: { false }, commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in try machine.submit(request) }, normalizeCreateTarget: { $0 })
        let recorder = ComponentWriteRecorder(coordinator: coordinator)
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(catalog: { _ in [] },
            catalogGroups: { _ in ["Empty", "Visible"] }, requestStatus: { _, _ in nil },
            submitTextWrite: { request, _ in try recorder.submit(request) },
            commitTextWrite: { try recorder.commit($0, requestID: $1, capability: $2) }))
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        return Fixture(recorder: recorder, process: process, input: input, output: output)
    }

    private func call(_ name: String, _ arguments: [String: Any], fixture: Fixture) throws -> [String: Any] {
        try exchangeMCP(input: fixture.input, output: fixture.output, object: [
            "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
    }

    private func stop(_ fixture: Fixture) throws {
        try fixture.input.fileHandleForWriting.close()
        fixture.process.waitUntilExit()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
    }
}
