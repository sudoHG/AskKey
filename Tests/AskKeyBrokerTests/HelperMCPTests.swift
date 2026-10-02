import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperMCPTests: XCTestCase {
    func testPreToolUseIgnoresDiagnosticsAndProseButFindsWrappedConnections() throws {
        let (process, input, output) = try startMCPHelper(
            socketPath: "/tmp/ak-hook-command-\(UUID().uuidString.prefix(8)).sock"
        )
        let cases: [(String, Bool)] = [
            ("pwd", false), ("ssh -V", false), ("ssh -G example.test", false),
            ("ssh -Q key", false), ("ssh-keygen -l -f /tmp/test.pub", false),
            ("echo 'ssh user@example.test'", false),
            ("printf '%s' \"ssh user@example.test\"", false),
            ("cat /tmp/ssh-notes.txt", false),
            ("ssh user@example.test uptime", true),
            ("/usr/bin/ssh -o BatchMode=yes user@example.test uptime", true),
            ("pwd && ssh user@example.test uptime", true),
            ("env LC_ALL=C ssh user@example.test uptime", true),
            ("/bin/zsh -lc 'ssh user@example.test uptime'", true),
            ("'/usr/bin/ssh' user@example.test uptime", true),
            ("ssh user@example.test uptime 2>&1", true),
            ("ssh -o ProxyCommand=none -vG example.test", false),
            ("ssh user@example.test 'echo -V'", true),
            ("ssh -i \"$HOME/.ssh/id_ed25519\" user@example.test uptime", true),
            ("ssh -i ${HOME}/.ssh/id_ed25519 user@example.test uptime", true),
            ("cat <<'EOF'\nssh user@example.test\nEOF", false),
            ("/Applications/'Ask Key.app'/Contents/Helpers/askkey run --credential NAS -- ssh host uptime", false),
        ]
        for (command, shouldPause) in cases {
            let response = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
                "params": ["name": "credential_discovery_guard", "arguments": [
                    "session_id": "session", "turn_id": "turn", "tool_name": "Bash",
                    "tool_input": ["command": command],
                ]],
            ])
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcpText(response).utf8)) as? [String: Any])
            XCTAssertEqual(body["hookSpecificOutput"] != nil, shouldPause, command)
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testPreToolUsePausesSSHUntilCatalogAttemptInSameTurnWithoutBroker() throws {
        let (process, input, output) = try startMCPHelper(
            socketPath: "/tmp/ak-hook-missing-\(UUID().uuidString.prefix(8)).sock"
        )
        func hook(tool: String, command: String = "", turn: String = "turn-1", session: String = "test-session") throws -> [String: Any] {
            let response = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
                "params": ["name": "credential_discovery_guard", "arguments": [
                    "session_id": session, "turn_id": turn, "tool_name": tool,
                    "tool_input": ["command": command],
                ]],
            ])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcpText(response).utf8)) as? [String: Any])
        }
        let denied = try hook(tool: "Bash", command: "/usr/bin/ssh -o BatchMode=yes test@192.0.2.10 uptime")
        let decision = try XCTUnwrap(denied["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(decision["permissionDecision"] as? String, "deny")
        XCTAssertTrue((decision["permissionDecisionReason"] as? String ?? "").contains("list_credentials"))
        let scheduled = try hook(tool: "mcp__askkey__list_credentials")
        let scheduledOther = try hook(tool: "mcp__askkey__list_credentials", session: "other-session")
        let updated = try XCTUnwrap((scheduled["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])
        let updatedOther = try XCTUnwrap((scheduledOther["hookSpecificOutput"] as? [String: Any])?["updatedInput"] as? [String: Any])
        // Merely scheduling a lookup must not release another parallel SSH.
        XCTAssertNotNil(try hook(tool: "Bash", command: "ssh test@192.0.2.10 uptime")["hookSpecificOutput"])
        let lookup = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": "lookup", "method": "tools/call",
            "params": ["name": "list_credentials", "arguments": updated],
        ])
        XCTAssertEqual((lookup["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(try hook(tool: "Bash", command: "ssh test@192.0.2.10 uptime").isEmpty)
        XCTAssertNotNil(try hook(tool: "Bash", command: "ssh test@192.0.2.10 uptime", turn: "turn-2")["hookSpecificOutput"])
        XCTAssertNotNil(try hook(tool: "Bash", command: "ssh test@192.0.2.10 uptime", session: "other-session")["hookSpecificOutput"])
        _ = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": "lookup-other", "method": "tools/call",
            "params": ["name": "list_credentials", "arguments": updatedOther],
        ])
        XCTAssertTrue(try hook(tool: "Bash", command: "ssh test@192.0.2.10 uptime", session: "other-session").isEmpty)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPReadOnlyDiscoveryDoesNotLabelExecutionOrWritesReadOnly() throws {
        let (process, input, output) = try startMCPHelper(
            socketPath: "/tmp/ak-annotation-\(UUID().uuidString.prefix(8)).sock"
        )
        let response = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": "annotations", "method": "tools/list", "params": [:],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let definitions = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let readOnly = Set(["connection_status", "list_credentials", "request_status"])
        XCTAssertEqual(Set(definitions.compactMap { $0["name"] as? String }).intersection(readOnly), readOnly)
        for tool in definitions {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = tool["annotations"] as? [String: Any]
            if readOnly.contains(name) {
                XCTAssertEqual(annotations?["readOnlyHint"] as? Bool, true, name)
                XCTAssertEqual(annotations?["openWorldHint"] as? Bool, false, name)
            } else {
                XCTAssertNotEqual(annotations?["readOnlyHint"] as? Bool, true, name)
            }
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPUsageContractExplainsCredentialWorkflow() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-contract-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let (process, input, output) = try startMCPHelper(
            socketPath: directory.appendingPathComponent("broker.sock").path
        )

        let initialize = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0",
            "id": "initialize",
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "usage-contract-test", "version": "1"],
            ],
        ])
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        let instructions = try XCTUnwrap(initializeResult["instructions"] as? String)
        let instructionText = instructions.lowercased()
        XCTAssertTrue(instructionText.contains("credential"), instructions)
        XCTAssertTrue(instructionText.contains("list_credentials"), instructions)
        XCTAssertTrue(instructionText.contains("run"), instructions)
        XCTAssertTrue(instructionText.contains("approval"), instructions)

        let listed = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0",
            "id": "tools",
            "method": "tools/list",
            "params": [:],
        ])
        let listedResult = try XCTUnwrap(listed["result"] as? [String: Any])
        let definitions = try XCTUnwrap(listedResult["tools"] as? [[String: Any]])
        func definition(named name: String) throws -> [String: Any] {
            try XCTUnwrap(definitions.first { $0["name"] as? String == name })
        }
        func serializedText(_ value: Any) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                .lowercased()
        }

        let listCredentials = try definition(named: "list_credentials")
        let listDescription = try XCTUnwrap(listCredentials["description"] as? String)
        let listText = listDescription.lowercased()
        XCTAssertTrue(listText.contains("nas"), listDescription)
        XCTAssertTrue(listText.contains("ssh"), listDescription)
        XCTAssertTrue(listText.contains("name"), listDescription)
        XCTAssertTrue(listText.contains("id") && listText.contains("not"), listDescription)

        let run = try definition(named: "run")
        let runDescription = try XCTUnwrap(run["description"] as? String)
        let runText = runDescription.lowercased()
        XCTAssertTrue(runText.contains("approvalrequired"), runDescription)
        XCTAssertTrue(runText.contains("operation_id") || runText.contains("operation id"), runDescription)
        XCTAssertTrue(runText.contains("same"), runDescription)
        XCTAssertTrue(runText.contains("retry") || runText.contains("re-submit") || runText.contains("resubmit"), runDescription)
        XCTAssertTrue(runText.contains("automatically") && runText.contains("not"), runDescription)
        XCTAssertTrue(runText.contains("output") && (runText.contains("cli") || runText.contains("command-line")), runDescription)

        let inputSchema = try XCTUnwrap(run["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let credentials = try XCTUnwrap(properties["credentials"] as? [String: Any])
        XCTAssertEqual(credentials["type"] as? String, "array")
        let credentialItems = try XCTUnwrap(credentials["items"] as? [String: Any])
        XCTAssertEqual(credentialItems["type"] as? String, "string")
        let credentialContract = try serializedText(credentials)
        XCTAssertTrue(credentialContract.contains("name"), credentialContract)
        XCTAssertTrue(credentialContract.contains("id") && credentialContract.contains("not"), credentialContract)

        let command = try XCTUnwrap(properties["command"] as? [String: Any])
        XCTAssertEqual(command["type"] as? String, "array")
        let commandContract = try serializedText(command)
        XCTAssertTrue(commandContract.contains("environment") || commandContract.contains("env"), commandContract)
        XCTAssertTrue(commandContract.contains("deliver"), commandContract)

        let operationID = try XCTUnwrap(properties["operation_id"] as? [String: Any])
        let operationContract = try serializedText(operationID)
        XCTAssertTrue(operationContract.contains("same"), operationContract)
        XCTAssertTrue(operationContract.contains("approval"), operationContract)
        let required = (inputSchema["required"] as? [String]) ?? []
        XCTAssertFalse(required.contains("operation_id"), "operation_id remains compatible as optional input")

        // The route shown to an Agent must point at the actual helper, rather
        // than an invented PATH command that may resolve to another install.
        let helperPath = try helperExecutable().standardizedFileURL.resolvingSymlinksInPath().path
        let contractText = [instructions, listDescription, runDescription]
            .joined(separator: "\n")
            .lowercased()
        XCTAssertTrue(contractText.contains(helperPath.lowercased()), contractText)

        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPRunApprovalResumesWithSameOperationAndReplaysWithoutRerun() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
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

    func testMulticaConfigurationUsesRunningHelperPath() throws {
        let value = try multicaConfiguration()
        XCTAssertEqual(value?["command"] as? String, try helperExecutable().standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(value?["args"] as? [String], ["mcp"])
        if let root = try DebugRunDirectory.resolve() {
            XCTAssertEqual(value?.count, 3)
            XCTAssertEqual(value?["env"] as? [String: String], ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path])
        } else {
            XCTAssertEqual(value?.count, 2)
            XCTAssertNil(value?["env"])
        }
    }

    func testMulticaRuntimeRestartsHelperFromAuthoritativeConfiguration() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-mr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let server = try startHealthServer(socketPath: socketPath)
        addTeardownBlock { server.stop() }
        let runtime = MulticaTestRuntime(
            configuration: try XCTUnwrap(multicaConfiguration()),
            resolveExecutable: { configuredPath in
                configuredPath == (try? self.helperExecutable().standardizedFileURL.resolvingSymlinksInPath().path)
                    ? try? self.helperExecutable()
                    : nil
            },
            socketPath: socketPath
        )
        addTeardownBlock { runtime.stop() }

        var session = try runtime.start()
        XCTAssertEqual(
            try connectionStatus(
                processInput: session.input,
                processOutput: session.output,
                id: 1
            )["status"] as? String,
            "connected"
        )

        let reconnection = try runtime.reconnectAfterDisconnect()
        XCTAssertEqual(reconnection.failure, .helperExited(0))
        session = reconnection.session
        XCTAssertEqual(
            try connectionStatus(
                processInput: session.input,
                processOutput: session.output,
                id: 2
            )["status"] as? String,
            "connected"
        )
        runtime.stop()
    }

    func testMCPConnectionStatusTracksBrokerDisconnectAndReconnect() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-mc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path

        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        XCTAssertEqual(
            try connectionStatus(processInput: input, processOutput: output, id: 1)["status"] as? String,
            "broker_unavailable"
        )
        let unavailable = try callMCPTool(
            processInput: input,
            processOutput: output,
            id: 10,
            name: "list_credentials"
        )
        XCTAssertEqual((unavailable["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unavailableStatus = try JSONSerialization.jsonObject(
            with: Data(mcpText(unavailable).utf8)
        ) as? [String: Any]
        XCTAssertEqual(unavailableStatus?["status"] as? String, "broker_unavailable")

        var server: BrokerSocketServer? = try startHealthServer(socketPath: socketPath)
        var status = try connectionStatus(processInput: input, processOutput: output, id: 2)
        XCTAssertEqual(status["status"] as? String, "connected")
        XCTAssertEqual(status["helperVersion"] as? String, "0.1.0")
        XCTAssertEqual(status["mcpProtocolVersion"] as? String, "2024-11-05")
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current)

        server?.stop()
        server = nil
        XCTAssertEqual(
            try connectionStatus(processInput: input, processOutput: output, id: 3)["status"] as? String,
            "broker_unavailable"
        )

        server = try startHealthServer(socketPath: socketPath)
        status = try connectionStatus(processInput: input, processOutput: output, id: 4)
        XCTAssertEqual(status["status"] as? String, "connected")
        server?.stop()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPConnectionStatusReportsProtocolIncompatibility() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-mv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let replied = expectation(description: "incompatible broker replied")
        try startResponseServer(
            socketPath: socketPath,
            responses: [.success(.version(.init(protocolVersion: BrokerProtocolVersion.current + 1)))],
            replied: replied
        )

        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let status = try connectionStatus(processInput: input, processOutput: output, id: 1)
        XCTAssertEqual(status["status"] as? String, "protocol_incompatible")
        XCTAssertEqual(status["helperProtocolVersion"] as? Int, BrokerProtocolVersion.current)
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current + 1)
        wait(for: [replied], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPConnectionStatusRejectsMismatchedHealthVersion() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-mh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let replied = expectation(description: "mismatched health replied")
        try startResponseServer(
            socketPath: socketPath,
            responses: [
                .success(.version(.init(protocolVersion: BrokerProtocolVersion.current))),
                .success(.health(.init(version: BrokerProtocolVersion.current + 1, status: "ok"))),
            ],
            replied: replied
        )
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let status = try connectionStatus(processInput: input, processOutput: output, id: 1)
        XCTAssertEqual(status["status"] as? String, "protocol_incompatible")
        XCTAssertEqual(status["brokerProtocolVersion"] as? Int, BrokerProtocolVersion.current + 1)
        wait(for: [replied], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPToolReportsBrokerDisconnectWithoutResponse() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-md-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let disconnected = expectation(description: "broker disconnected")
        try startResponseServer(socketPath: socketPath, responses: [nil], replied: disconnected)
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)

        let failure = try callMCPTool(
            processInput: input,
            processOutput: output,
            id: 1,
            name: "list_credentials"
        )
        let status = try JSONSerialization.jsonObject(
            with: Data(mcpText(failure).utf8)
        ) as? [String: Any]
        XCTAssertEqual(status?["status"] as? String, "broker_disconnected")
        wait(for: [disconnected], timeout: 2)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPBoundsFramesAndRecoversFromBrokerFailureWithoutReturningTargetOutput() throws {
        let suffix = UUID().uuidString.prefix(8)
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
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
            #"{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"multica-test","version":"1"}}}"#,
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
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
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

    func testMCPMixedComponentsRoundTripPreservesPayloadReferencesAndOperationIdentity() throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
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

    private func exchangeMCP(input: Pipe, output: Pipe, object: [String: Any]) throws -> [String: Any] {
        var encoded = try JSONSerialization.data(withJSONObject: object)
        encoded.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: encoded)
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte[0] == 0x0A { break }
            line.append(byte)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
    }

    private func helperExecutable() throws -> URL {
        let executable = Bundle(for: HelperMCPTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }

    private func multicaConfiguration() throws -> [String: Any]? {
        let command = try helperExecutable().standardizedFileURL.resolvingSymlinksInPath().path
        let configuration = try MulticaServerConfiguration.make(command: command, args: ["mcp"])
        var value: [String: Any] = [
            "command": configuration.command,
            "args": configuration.args,
        ]
        if let env = configuration.env {
            value["env"] = env
        }
        return value
    }

    private func startMCPHelper(socketPath: String) throws -> (Process, Pipe, Pipe) {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ASKKEY_DEBUG_RUN_DIRECTORY")
        environment["ASKKEY_BROKER_SOCKET"] = socketPath
        environment["ASKKEY_UNRELATED_TEST_VALUE"] = "must-not-cross-helper-boundary"
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock {
            if process.isRunning { process.terminate() }
        }
        return (process, input, output)
    }

    private func mcpText(_ response: [String: Any]) throws -> String {
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw CocoaError(.coderReadCorrupt)
        }
        return text
    }

    private func startHealthServer(socketPath: String) throws -> BrokerSocketServer {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        return server
    }

    private func connectionStatus(processInput: Pipe, processOutput: Pipe, id: Int) throws -> [String: Any] {
        let response = try callMCPTool(
            processInput: processInput,
            processOutput: processOutput,
            id: id,
            name: "connection_status"
        )
        guard let text = try? mcpText(response),
              let status = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return status
    }

    private func callMCPTool(
        processInput: Pipe,
        processOutput: Pipe,
        id: Int,
        name: String
    ) throws -> [String: Any] {
        let request = """
        {"jsonrpc":"2.0","id":\(id),"method":"tools/call","params":{"name":"\(name)","arguments":{}}}
        """
        try processInput.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        let line = processOutput.fileHandleForReading.availableData
        guard !line.isEmpty,
              let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return response
    }

    private func startResponseServer(
        socketPath: String,
        responses: [BrokerResponse?],
        replied: XCTestExpectation
    ) throws {
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { throw BrokerSocketError.pathTooLong }
        _ = withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
            socketPath.withCString { strncpy(destination, $0, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listenFD, 1) == 0 else {
            close(listenFD)
            throw BrokerSocketError.systemError("bind/listen", errno)
        }
        DispatchQueue.global().async {
            defer { close(listenFD); replied.fulfill() }
            for response in responses {
                let fd = accept(listenFD, nil, nil)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var header = Data(count: 4)
                guard Self.readAll(fd: fd, into: &header) else { return }
                let length = header.reduce(0) { ($0 << 8) | Int($1) }
                var body = Data(count: length)
                guard Self.readAll(fd: fd, into: &body) else { return }
                guard let response,
                      let encoded = try? JSONEncoder().encode(response) else { continue }
                var frame = Data([
                    UInt8((encoded.count >> 24) & 0xff), UInt8((encoded.count >> 16) & 0xff),
                    UInt8((encoded.count >> 8) & 0xff), UInt8(encoded.count & 0xff),
                ])
                frame.append(encoded)
                XCTAssertTrue(Self.writeAll(fd: fd, data: frame))
            }
        }
    }

    private static func readAll(fd: Int32, into data: inout Data) -> Bool {
        data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = read(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}

private final class MulticaTestRuntime {
    typealias Session = (process: Process, input: Pipe, output: Pipe)
    enum Failure: Equatable { case helperExited(Int32) }

    private let configuration: [String: Any]
    private let resolveExecutable: (String) -> URL?
    private let socketPath: String
    private var session: Session?

    init(
        configuration: [String: Any],
        resolveExecutable: @escaping (String) -> URL?,
        socketPath: String
    ) {
        self.configuration = configuration
        self.resolveExecutable = resolveExecutable
        self.socketPath = socketPath
    }

    func start() throws -> Session {
        guard session == nil,
              let command = configuration["command"] as? String,
              let executableURL = resolveExecutable(command),
              let arguments = configuration["args"] as? [String],
              arguments == ["mcp"] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "ASKKEY_DEBUG_RUN_DIRECTORY")
        environment["ASKKEY_BROKER_SOCKET"] = socketPath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let session = (process, input, output)
        self.session = session
        return session
    }

    func reconnectAfterDisconnect() throws -> (failure: Failure, session: Session) {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        try session.input.fileHandleForWriting.close()
        session.process.waitUntilExit()
        self.session = nil
        return (.helperExited(session.process.terminationStatus), try start())
    }

    func stop() {
        guard let session else { return }
        if session.process.isRunning { session.process.terminate() }
        session.process.waitUntilExit()
        self.session = nil
    }
}

private final class FileWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    var receivedBytes: Data {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }

    func handle(_ request: BrokerFileWriteRequest) throws -> BrokerFileWritePayload {
        lock.lock(); defer { lock.unlock() }
        switch request {
        case .beginComponent, .freezeComponent, .cancelUpload:
            throw BrokerFileWriteError.invalidRequest
        case .begin(let begin):
            guard begin.operationID == "write-operation",
                  begin.credentialID == "credential-id",
                  begin.targetID == "credential-id",
                  begin.operation == .modify,
                  begin.originalFilename == "AuthKey.p8",
                  begin.expectedByteCount == 17 else {
                throw BrokerFileWriteError.invalidRequest
            }
            return .upload(.init(uploadID: "upload-id", capability: "upload-capability"))
        case .append(let append):
            guard append.uploadID == "upload-id",
                  append.capability == "upload-capability",
                  append.offset == bytes.count else {
                throw BrokerFileWriteError.invalidRequest
            }
            bytes.append(append.bytes)
            return .chunkAccepted(nextOffset: bytes.count)
        case .freeze(let freeze):
            guard freeze.uploadID == "upload-id",
                  freeze.capability == "upload-capability",
                  bytes == Data("file-write-secret".utf8) else {
                throw BrokerFileWriteError.invalidRequest
            }
            return .approval(.init(
                requestID: "approval-id",
                capability: "approval-capability",
                state: .pending,
                retryCount: 0
            ))
        }
    }
}

private final class RuntimeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: BrokerTextRunRequest?

    var request: BrokerTextRunRequest? {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ request: BrokerTextRunRequest) {
        lock.lock(); defer { lock.unlock() }
        recorded = request
    }
}

private final class PendingRunTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var approved = false
    private var resolverCalls = 0
    private var starts = 0

    var isApproved: Bool {
        lock.lock(); defer { lock.unlock() }
        return approved
    }

    var resolverCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return resolverCalls
    }

    var spawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return starts
    }

    func recordResolverCall() {
        lock.lock(); defer { lock.unlock() }
        resolverCalls += 1
    }

    func recordSpawn() {
        lock.lock(); defer { lock.unlock() }
        starts += 1
    }

    func approve() {
        lock.lock(); defer { lock.unlock() }
        approved = true
    }
}

private final class RuntimeEnvironmentRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []

    var values: [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func record(_ environment: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(environment)
    }
}

/// Records the Helper wire boundary. Persistence/approval atomicity is exercised
/// by AuditBrokerBoundaryTests; this fixture does not imitate a Vault.
private final class ComponentWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator: BrokerFileWriteCoordinator
    private var recordedSubmissions: [AgentTextWriteRequest] = []
    private var recordedCommits: [AgentTextWriteRequest] = []
    init(coordinator: BrokerFileWriteCoordinator) { self.coordinator = coordinator }
    var submissions: [AgentTextWriteRequest] { lock.lock(); defer { lock.unlock() }; return recordedSubmissions }
    var commits: [AgentTextWriteRequest] { lock.lock(); defer { lock.unlock() }; return recordedCommits }
    func submit(_ request: AgentTextWriteRequest) throws -> AgentTextWriteRequestOutcome {
        for reference in request.componentFileReferences {
            _ = try coordinator.resolveComponent(reference, operationID: request.operationID)
        }
        lock.lock(); defer { lock.unlock() }
        recordedSubmissions.append(request)
        return .submitted(.init(operationID: request.operationID, requestID: "request-" + request.operationID,
            capability: "synthetic-approval-capability", state: .pending, retryCount: 0))
    }
    func commit(_ request: AgentTextWriteRequest, requestID: String, capability: String) throws -> AgentTextWriteResult {
        guard requestID == "request-" + request.operationID, capability == "synthetic-approval-capability" else {
            throw BrokerApprovalError.requestNotFound
        }
        lock.lock(); defer { lock.unlock() }
        recordedCommits.append(request)
        return .init(operationID: request.operationID, credentialID: "synthetic-credential-id")
    }
}
