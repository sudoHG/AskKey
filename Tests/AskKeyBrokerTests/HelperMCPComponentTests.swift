import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperMCPComponentTests: HelperMCPTestCase {
    func testMCPMixedComponentsRoundTripPreservesPayloadReferencesAndOperationIdentity() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-mix-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let approvals = BrokerApprovalStateMachine()
        let coordinator = try BrokerFileWriteCoordinator(
            stagingDirectory: directory.appendingPathComponent("uploads"), approvals: approvals,
            authenticateReveal: { false }, commitFrozenFile: { _ in },
            submitFrozenApproval: { _, _, request in try approvals.submit(request) },
            normalizeCreateTarget: { $0 })
        let recorder = ComponentWriteRecorder(coordinator: coordinator)
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { _ in [] }, requestStatus: { _, _ in nil },
            fileWrite: { try coordinator.handle($0) },
            submitTextWrite: { request, _ in try recorder.submit(request) },
            commitTextWrite: { try recorder.commit($0, requestID: $1, capability: $2) }))
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        var responses: [[String: Any]] = []
        var nextID = 1
        func call(_ name: String, _ arguments: [String: Any]) throws -> BrokerResponse {
            defer { nextID += 1 }
            let response = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": nextID, "method": "tools/call",
                "params": ["name": name, "arguments": arguments]])
            responses.append(response)
            return try JSONDecoder().decode(BrokerResponse.self, from: Data(mcpText(response).utf8))
        }
        let fileBytes = Data("synthetic-uploaded-component".utf8)
        guard case .success(.fileWrite(.upload(let upload))) = try call("begin_component_upload", [
            "operation_id": "mixed-create", "filename": "key.pem", "byte_count": fileBytes.count]) else {
            return XCTFail("Expected actual coordinator upload response")
        }
        guard case .success(.fileWrite(.chunkAccepted(let offset))) = try call("append_component_upload", [
            "upload_id": upload.uploadID, "capability": upload.capability,
            "offset": 0, "chunk_base64": fileBytes.base64EncodedString()]) else {
            return XCTFail("Expected accepted chunk")
        }
        XCTAssertEqual(offset, fileBytes.count)
        guard case .success(.fileWrite(.componentFrozen(let reference))) = try call("freeze_component_upload", [
            "upload_id": upload.uploadID, "capability": upload.capability]) else {
            return XCTFail("Expected actual frozen reference")
        }
        let fileReference: [String: Any] = ["upload_id": reference.uploadID,
            "capability": reference.capability, "digest": reference.digest]
        let components: [[String: Any]] = [
            ["name": "token", "text": "synthetic-token", "delivery": ["type": "environment_variable", "environment_variable": "SERVICE_TOKEN"]],
            ["name": "key", "file": fileReference, "delivery": ["type": "temporary_file", "environment_variable": "SERVICE_KEY"]],
            ["name": "memo", "text": "synthetic-memo", "delivery": ["type": "none"], "masked": false],
        ]
        var create: [String: Any] = ["name": "Mixed", "operation_id": "mixed-create", "components": components]
        guard case .success(.textWriteRequest(.submitted(let ticket))) = try call("create_credential", create) else {
            return XCTFail("Expected whole request forwarded")
        }
        guard case .success(.textWriteRequest(.submitted(let replay))) = try call("create_credential", create) else {
            return XCTFail("Expected exact operation replay")
        }
        XCTAssertEqual(ticket.requestID, replay.requestID)
        XCTAssertEqual(recorder.submissions.count, 2)
        XCTAssertEqual(recorder.submissions[0], recorder.submissions[1])
        XCTAssertEqual(recorder.submissions[0].action, .createBundle(name: "Mixed", components: [
            .init(name: "token", value: .text("synthetic-token"), delivery: .environmentVariable("SERVICE_TOKEN")),
            .init(name: "key", value: .file(reference), delivery: .temporaryFile("SERVICE_KEY")),
            .init(name: "memo", value: .text("synthetic-memo"), delivery: .none, masked: false),
        ]))
        XCTAssertEqual(try coordinator.resolveComponent(reference, operationID: "mixed-create").bytes, fileBytes)
        create["request_id"] = ticket.requestID
        create["capability"] = ticket.capability
        guard case .success(.textWriteResult(let result)) = try call("create_credential", create) else {
            return XCTFail("Expected commit request forwarded")
        }
        XCTAssertEqual(result.operationID, "mixed-create")
        XCTAssertEqual(recorder.commits, [recorder.submissions[0]])
        let modify: [String: Any] = ["name": "Mixed", "operation_id": "mixed-modify", "changes": [
            ["upsert": ["name": "token", "text": "synthetic-updated", "delivery": ["type": "environment_variable", "environment_variable": "NEW_TOKEN"]]],
        ]]
        _ = try call("modify_credential", modify)
        XCTAssertEqual(recorder.submissions.last?.action, .modifyBundle(name: "Mixed", changes: [
            .upsert(.init(name: "token", value: .text("synthetic-updated"), delivery: .environmentVariable("NEW_TOKEN"))),
        ]))
        // A real coordinator rejects both cross-operation references and a wrong
        // capability; the helper must surface the rejection, never report success.
        for (badOperation, badReference) in [("wrong-operation", fileReference), ("mixed-create", ["upload_id": reference.uploadID,
             "capability": "wrong-capability", "digest": reference.digest])] {
            let rejection = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": 90, "method": "tools/call", "params": [
                    "name": "create_credential", "arguments": ["name": "Bad", "operation_id": badOperation,
                        "components": [["name": "file", "file": badReference, "delivery": ["type": "none"]]]]]])
            responses.append(rejection)
            XCTAssertEqual((rejection["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertEqual(recorder.submissions.count, 3)
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: responses), as: UTF8.self)
        for secret in ["synthetic-token", "synthetic-memo", "synthetic-updated", "synthetic-uploaded-component"] {
            XCTAssertFalse(serialized.contains(secret))
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
