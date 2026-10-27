import XCTest
@testable import AskKeyBroker

final class HelperWorkingDirectoryTests: HelperMCPTestCase {
    func testMCPRunSchemaAndInstructionsRequireAbsoluteDirectory() throws {
        let directory = try makeDirectory()
        let (process, input, output) = try startMCPHelper(socketPath: directory.appendingPathComponent("broker.sock").path)
        let initialized = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2024-11-05", "capabilities": [:],
                "clientInfo": ["name": "synthetic-client", "version": "1"],
            ],
        ])
        let instructions = try XCTUnwrap((initialized["result"] as? [String: Any])?["instructions"] as? String)
        XCTAssertTrue(instructions.contains("MCP run requires cwd"))
        let listed = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:],
        ])
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let run = try XCTUnwrap(tools.first { $0["name"] as? String == "run" })
        let schema = try XCTUnwrap(run["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["required"] as? [String], ["credentials", "command", "cwd"])
        XCTAssertTrue((run["description"] as? String ?? "").contains("MCP run requires cwd"))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMCPRejectsInvalidDirectoryBeforeBrokerAndForwardsAbsoluteDirectoryUnchanged() throws {
        let directory = try makeDirectory()
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let captured = RuntimeRequestRecorder()
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { _ in [] }, requestStatus: { _, _ in nil },
            textRun: { request, _, _ in captured.record(request); return .exited(0) }
        ))
        try server.start()
        addTeardownBlock { server.stop() }
        let (process, input, output) = try startMCPHelper(socketPath: socketPath)
        let invalid: [[String: Any]] = [
            [:], ["cwd": NSNull()], ["cwd": 42], ["cwd": false], ["cwd": ["/"]],
            ["cwd": ""], ["cwd": "."], ["cwd": "relative/project"], ["cwd": "~/project"], ["cwd": "/tmp\0other"],
        ]
        for fields in invalid {
            var arguments: [String: Any] = [
                "credentials": ["Synthetic"], "command": ["/bin/pwd"], "operation_id": "directory-validation",
            ]
            arguments.merge(fields) { _, new in new }
            let response = try exchangeMCP(input: input, output: output, object: [
                "jsonrpc": "2.0", "id": UUID().uuidString, "method": "tools/call",
                "params": ["name": "run", "arguments": arguments],
            ])
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(mcpText(response).utf8)) as? [String: String])
            XCTAssertEqual(payload["status"], "invalid_working_directory")
            XCTAssertTrue(payload["next_step"]?.contains("absolute working directory you want the command to run in") == true)
            XCTAssertNil(captured.request, "invalid cwd must not reach the Broker")
        }
        let response = try exchangeMCP(input: input, output: output, object: [
            "jsonrpc": "2.0", "id": "absolute", "method": "tools/call", "params": [
                "name": "run", "arguments": ["credentials": ["Synthetic"], "command": ["/bin/pwd"],
                    "operation_id": "directory-validation", "cwd": directory.path],
            ],
        ])
        XCTAssertEqual(try JSONDecoder().decode(BrokerTextRunResult.self, from: Data(mcpText(response).utf8)), .exited(0))
        XCTAssertEqual(captured.request?.workingDirectory, directory.path)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testCLIDefaultsToItsOwnDirectoryAndExecutesThere() throws {
        let directory = try makeDirectory()
        let targetDirectory = directory.appendingPathComponent("project with spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: false)
        let socketPath = directory.appendingPathComponent("broker.sock").path
        let captured = RuntimeRequestRecorder()
        let runtime = BrokerTextRuntime(resolveCredentials: { _, _ in
            .resolved([.init(environmentVariable: "TOKEN", value: "synthetic-value")])
        })
        let server = BrokerSocketServer(socketPath: socketPath, handler: .init(
            catalog: { _ in [] }, requestStatus: { _, _ in nil },
            textRun: { request, descriptors, cancellation in
                captured.record(request)
                return try runtime.run(request, standardInputFD: descriptors.standardInput,
                    standardOutputFD: descriptors.standardOutput, standardErrorFD: descriptors.standardError,
                    controlFD: descriptors.control, cancellation: cancellation)
            }
        ))
        try server.start()
        addTeardownBlock { server.stop() }
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = ["run", "--credential", "Synthetic", "--", "/bin/pwd", "-P"]
        process.currentDirectoryURL = targetDirectory
        process.environment = helperTestEnvironment(overrides: ["ASKKEY_BROKER_SOCKET": socketPath])
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() } }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(captured.request?.workingDirectory, targetDirectory.path)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), targetDirectory.path + "\n")
    }

    private func makeDirectory() throws -> URL {
        let directory = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-cwd-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
