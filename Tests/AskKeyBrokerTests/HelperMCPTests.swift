import XCTest
@testable import AskKeyBroker
import Darwin

final class HelperMCPTests: HelperMCPTestCase {
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
        let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
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
}
