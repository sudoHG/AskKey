import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperMCPRunTests: HelperMCPTestCase {
    func testMCPRunApprovalResumesWithSameOperationAndReplaysWithoutRerun() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-run-approval-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let state = PendingRunTestState()
        let ticket = BrokerApprovalTicket(
            requestID: "run-approval-request",
            capability: "run-approval-capability",
            state: .pending,
            retryCount: 0
        )
        let runtime = BrokerTextRuntime(
            resolveCredentials: { _, _ in
                state.recordResolverCall()
                if !state.isApproved {
                    return .approvalRequired([ticket])
                }
                return .resolved([
                    .init(environmentVariable: "TOKEN", value: "synthetic-secret-should-not-return"),
                ])
            },
            beforeSystemSpawn: {
                state.recordSpawn()
            }
        )
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { _ in [] },
                requestStatus: { _, _ in nil },
                textRun: { request, descriptors, cancellation in
                    try runtime.run(
                        request,
                        standardInputFD: descriptors.standardInput,
                        standardOutputFD: descriptors.standardOutput,
                        standardErrorFD: descriptors.standardError,
                        controlFD: descriptors.control,
                        cancellation: cancellation
                    )
                }
            )
        )
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        let operationID = "nas-ssh-check"
        let command = ["/bin/sh", "-c", "printf target-output-should-not-return; exit 0"]
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "run",
                "arguments": [
                    "credentials": ["NAS_SSH"],
                    "command": command,
                    "operation_id": operationID,
                ],
            ],
        ]

        let pending = try exchangeMCP(input: input, output: output, object: request)
        let pendingContent = try XCTUnwrap(
            (pending["result"] as? [String: Any])?["content"] as? [[String: Any]]
        )
        XCTAssertEqual(pendingContent.count, 2)
        let pendingPayload = try XCTUnwrap(pendingContent.first?["text"] as? String)
        let pendingResult = try JSONDecoder().decode(
            BrokerTextRunResult.self,
            from: Data(pendingPayload.utf8)
        )
        guard case .approvalRequired(let returnedOperationID, let tickets) = pendingResult else {
            return XCTFail("Expected the first MCP run to require approval")
        }
        XCTAssertEqual(returnedOperationID, operationID)
        XCTAssertEqual(tickets, [ticket])
        let continuation = try XCTUnwrap(pendingContent[1]["text"] as? String)
        let continuationText = continuation.lowercased()
        XCTAssertTrue(continuation.contains(operationID), continuation)
        XCTAssertTrue(continuationText.contains("retry") || continuationText.contains("re-submit") || continuationText.contains("resubmit"), continuation)
        XCTAssertTrue(continuationText.contains("same") || continuationText.contains("operation_id"), continuation)
        let pendingWire = String(decoding: try JSONSerialization.data(withJSONObject: pending), as: UTF8.self)
        XCTAssertFalse(pendingWire.contains("target-output-should-not-return"), pendingWire)
        XCTAssertFalse(pendingWire.contains("synthetic-secret-should-not-return"), pendingWire)

        // Simulate the user approving the pending request. The Agent must
        // retry the exact same request with the same operation_id.
        state.approve()
        var resumedRequest = request
        resumedRequest["id"] = 2
        let resumed = try exchangeMCP(input: input, output: output, object: resumedRequest)
        let resumedPayload = try mcpText(resumed)
        XCTAssertEqual(
            try JSONDecoder().decode(BrokerTextRunResult.self, from: Data(resumedPayload.utf8)),
            .exited(0)
        )

        var replayRequest = request
        replayRequest["id"] = 3
        let replay = try exchangeMCP(input: input, output: output, object: replayRequest)
        XCTAssertEqual(try mcpText(replay), resumedPayload)
        XCTAssertEqual(state.resolverCallCount, 2)
        XCTAssertEqual(state.spawnCount, 1)
        let allWire = String(
            decoding: try JSONSerialization.data(withJSONObject: [resumed, replay]),
            as: UTF8.self
        )
        XCTAssertFalse(allWire.contains("target-output-should-not-return"), allWire)
        XCTAssertFalse(allWire.contains("synthetic-secret-should-not-return"), allWire)

        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPBoundsFramesAndRecoversFromBrokerFailureWithoutReturningTargetOutput() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let runtimeEnvironments = RuntimeEnvironmentRecorder()
        let runtime = BrokerTextRuntime(resolveCredentials: { request, _ in
            runtimeEnvironments.record(request.inheritedEnvironment)
            if request.credentialNames == ["REJECTED"] { throw BrokerProviderError.requestRejected }
            return .resolved([.init(environmentVariable: "TOKEN", value: "must-not-appear")])
        })
        let fileWrites = FileWriteRecorder()
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { _ in [
                    .init(
                        name: "TEST_FILE",
                        payloadKind: .file,
                        usageInstructions: "Use for the test service",
                        environmentVariable: nil,
                        expired: false
                    ),
                ] },
                requestStatus: { _, _ in nil },
                textRun: { request, descriptors, cancellation in
                    try runtime.run(
                        request,
                        standardInputFD: descriptors.standardInput,
                        standardOutputFD: descriptors.standardOutput,
                        standardErrorFD: descriptors.standardError,
                        controlFD: descriptors.control,
                        cancellation: cancellation
                    )
                },
                fileWrite: { try fileWrites.handle($0) }
            )
        )
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        var requests = Data(repeating: 0x78, count: 64 * 1024 + 1)
        requests.append(0x0A)
        requests.append(Data("{\n{}\n[]\n1\n".utf8))
        for line in [
            #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#,
            #"{"jsonrpc":"2.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"synthetic-mcp-client","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run","arguments":{"credentials":["REJECTED"],"command":["/usr/bin/true"]}}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"run","arguments":{"credentials":["TOKEN"],"command":["/bin/sh","-c","test \"$TOKEN\" = must-not-appear"]}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_credentials","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"begin_file_write","arguments":{"operation_id":"write-operation","credential_id":"credential-id","target_id":"credential-id","operation":"modify","filename":"AuthKey.p8","byte_count":17}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"append_file_write","arguments":{"upload_id":"upload-id","capability":"upload-capability","offset":0,"chunk_base64":"ZmlsZS13cml0ZS1zZWNyZXQ="}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"freeze_file_write","arguments":{"upload_id":"upload-id","capability":"upload-capability"}}}"#,
            #"{"jsonrpc":"2.0","id":7,"method":"ping","params":{}}"#,
        ] {
            requests.append(Data(line.utf8))
            requests.append(0x0A)
        }
        try input.fileHandleForWriting.write(contentsOf: requests)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let lines = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
        ).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 15)
        let responses = try lines.map { line -> [String: Any] in
            let data = Data(line.utf8)
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return value
        }
        XCTAssertEqual((responses[0]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[1]["error"] as? [String: Any])?["code"] as? Int, -32700)
        XCTAssertEqual((responses[2]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[3]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[4]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual((responses[5]["error"] as? [String: Any])?["code"] as? Int, -32600)
        XCTAssertEqual(responses[6]["id"] as? String, "initialize")
        let initialize = responses[6]["result"] as? [String: Any]
        XCTAssertEqual(initialize?["protocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual((initialize?["serverInfo"] as? [String: Any])?["name"] as? String, "askkey")
        XCTAssertEqual(responses[7]["id"] as? String, "tools")
        let definitions = (responses[7]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(
            Set(definitions?.compactMap { $0["name"] as? String } ?? []),
            [
                "connection_status", "list_credentials", "run", "credential_discovery_guard",
                "begin_file_write", "append_file_write", "freeze_file_write",
                "create_text_credential", "modify_text_credential", "delete_credential",
                "request_status", "request_cancel",
                "create_credential", "modify_credential", "begin_component_upload",
                "append_component_upload", "freeze_component_upload", "cancel_component_upload",
            ]
        )
        XCTAssertEqual(responses[8]["id"] as? Int, 1)
        XCTAssertEqual((responses[8]["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(responses[9]["id"] as? Int, 2)
        XCTAssertNil((responses[9]["result"] as? [String: Any])?["isError"])
        XCTAssertEqual(
            try JSONDecoder().decode(BrokerTextRunResult.self, from: Data(mcpText(responses[9]).utf8)),
            .exited(0)
        )
        XCTAssertEqual(responses[10]["id"] as? Int, 3)
        XCTAssertTrue(try mcpText(responses[10]).contains("TEST_FILE"))
        XCTAssertEqual(responses[11]["id"] as? Int, 4)
        XCTAssertEqual(responses[12]["id"] as? Int, 5)
        XCTAssertEqual(responses[13]["id"] as? Int, 6)
        XCTAssertEqual(responses[14]["id"] as? Int, 7)
        XCTAssertNotNil(responses[14]["result"])
        XCTAssertEqual(fileWrites.receivedBytes, Data("file-write-secret".utf8))
        XCTAssertTrue(runtimeEnvironments.values.allSatisfy { $0["ASKKEY_UNRELATED_TEST_VALUE"] == nil })
        XCTAssertTrue(runtimeEnvironments.values.allSatisfy { $0["PATH"] != nil })
        XCTAssertFalse(lines.joined().contains("must-not-appear"))
        XCTAssertFalse(lines.joined().contains("file-write-secret"))
    }

    func testMCPRunForwardsCallerDeclarationWithoutReturningSecrets() throws {
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-decl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let captured = RuntimeRequestRecorder()
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(
                catalog: { _ in [] },
                requestStatus: { _, _ in nil },
                textRun: { request, _, _ in
                    captured.record(request)
                    return .exited(0)
                }
            )
        )
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        let response = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "run",
                "arguments": [
                    "credentials": ["TOKEN"],
                    "command": ["/usr/bin/true"],
                    "caller_name": "Codex",
                    "caller_purpose": "publish",
                ],
            ],
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(BrokerTextRunResult.self, from: Data(mcpText(response).utf8)),
            .exited(0)
        )
        XCTAssertEqual(captured.request?.callerName, "Codex")
        XCTAssertEqual(captured.request?.callerPurpose, "publish")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self).contains("SECRET"))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
