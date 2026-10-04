import Foundation
import XCTest
@testable import AskKeyBroker

final class ClaudeDiscoveryHookTests: XCTestCase {
    func testPromptStartsTurnAndSSHIsDeniedWithoutExecutingInput() throws {
        let fixture = try Fixture()
        try fixture.prompt()
        let marker = fixture.root.appendingPathComponent("must-not-exist")
        let response = try fixture.event("PreToolUse", command: "ssh example.invalid uptime; touch '\(marker.path)'")
        let specific = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertTrue((specific["permissionDecisionReason"] as? String ?? "").contains("list_credentials"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let stored = try String(contentsOf: fixture.stateURL, encoding: .utf8)
        XCTAssertFalse(stored.contains("synthetic-session"))
        XCTAssertFalse(stored.contains("example.invalid"))
    }

    func testSuccessAndFailureSettleOnlyAfterMatchingCatalogPreEvent() throws {
        for completion in ["PostToolUse", "PostToolUseFailure"] {
            let fixture = try Fixture()
            try fixture.prompt()
            _ = try fixture.event(completion, tool: Fixture.catalog, call: "unstarted")
            XCTAssertTrue(try fixture.denied())
            _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lookup")
            XCTAssertTrue(try fixture.denied(), "Scheduling discovery does not settle it")
            _ = try fixture.event(completion, tool: Fixture.catalog, call: "other-lookup")
            XCTAssertTrue(try fixture.denied())
            _ = try fixture.event(completion, tool: Fixture.catalog, call: "lookup")
            XCTAssertFalse(try fixture.denied())
            try fixture.prompt()
            XCTAssertTrue(try fixture.denied(), "The next prompt starts a fresh turn")
        }
    }

    func testLateCallbackAndOtherSessionCannotSettleCurrentTurn() throws {
        let fixture = try Fixture()
        try fixture.prompt()
        _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "old")
        try fixture.prompt()
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "old")
        XCTAssertTrue(try fixture.denied())
        _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "current")
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "current", session: "other-session")
        XCTAssertTrue(try fixture.denied())
        _ = try fixture.event("PostToolUseFailure", tool: Fixture.catalog, call: "current")
        XCTAssertFalse(try fixture.denied())
    }

    func testNoProgressReleasesMissingCatalogAndLostCallback() throws {
        for pending in [false, true] {
            let fixture = try Fixture()
            try fixture.prompt()
            XCTAssertTrue(try fixture.denied())
            if pending { _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lost") }
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.stateURL)) as? [String: Any])
            var turns = try XCTUnwrap(state["turns"] as? [String: [String: Any]])
            for key in turns.keys { turns[key]?["touched"] = Date().timeIntervalSince1970 - 31 }
            state["turns"] = turns
            try JSONSerialization.data(withJSONObject: state).write(to: fixture.stateURL)
            XCTAssertFalse(try fixture.denied())
        }
    }

    func testUnrelatedToolsAndEventsAllowWithNoOutputOrState() throws {
        let fixture = try Fixture()
        for tool in ["Read", "Shell", "run_terminal_command", "mcp__other__list_credentials", "MCP:list_credentials"] {
            XCTAssertTrue(try fixture.event("PreToolUse", tool: tool).isEmpty)
        }
        for command in ["ls", "ssh -V", "ssh -G example.invalid", "echo ssh example.invalid"] {
            XCTAssertTrue(try fixture.event("PreToolUse", command: command).isEmpty)
        }
        for phase in ["PostToolUse", "PostToolUseFailure", "SessionStart", "unknown"] {
            XCTAssertTrue(try fixture.event(phase).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testMalformedInputAllowsWithNoOutput() throws {
        let fixture = try Fixture()
        for raw in ["", "{", "[]", "null", "{}", #"{"session_id":42,"hook_event_name":"UserPromptSubmit"}"#] {
            XCTAssertTrue(try fixture.call(Data(raw.utf8)).isEmpty)
        }
        var event = fixture.envelope("PreToolUse")
        for key in ["session_id", "hook_event_name", "tool_name", "tool_input", "tool_use_id"] {
            var malformed = event
            malformed.removeValue(forKey: key)
            XCTAssertTrue(try fixture.call(JSONSerialization.data(withJSONObject: malformed)).isEmpty)
        }
        event["session_id"] = ""
        XCTAssertTrue(try fixture.call(JSONSerialization.data(withJSONObject: event)).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testUnsafeStateFailsOpenWithoutChangingSymlinkTarget() throws {
        let fixture = try Fixture()
        let target = fixture.root.appendingPathComponent("keep.txt")
        let original = Data("synthetic untouched value".utf8)
        try original.write(to: target)
        try FileManager.default.createDirectory(at: fixture.stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: fixture.stateURL, withDestinationURL: target)
        try fixture.prompt()
        XCTAssertFalse(try fixture.denied())
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    private final class Fixture {
        static let catalog = "mcp__askkey__list_credentials"
        let root: URL
        var stateURL: URL { root.appendingPathComponent("credential-discovery/state.json") }
        init() throws {
            let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("askkey-claude-hook-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            root = try physicalTestDirectory(candidate)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func envelope(_ phase: String, tool: String = "Bash", call: String = "ssh",
                      session: String = "synthetic-session", command: String = "ssh example.invalid uptime") -> [String: Any] {
            ["hook_event_name": phase, "session_id": session, "tool_name": tool,
             "tool_use_id": call, "tool_input": ["command": command]]
        }
        func prompt() throws {
            XCTAssertTrue(try call(JSONSerialization.data(withJSONObject: [
                "hook_event_name": "UserPromptSubmit", "session_id": "synthetic-session"
            ])).isEmpty)
        }
        func event(_ phase: String, tool: String = "Bash", call: String = "ssh",
                   session: String = "synthetic-session", command: String = "ssh example.invalid uptime") throws -> [String: Any] {
            let data = try self.call(JSONSerialization.data(withJSONObject:
                envelope(phase, tool: tool, call: call, session: session, command: command)))
            if data.isEmpty { return [:] }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertFalse(response.isEmpty, "Allowed Claude hooks must emit no output")
            return response
        }
        func denied() throws -> Bool {
            (try event("PreToolUse")["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "deny"
        }
        func call(_ data: Data) throws -> Data {
            let process = Process()
            process.executableURL = Bundle(for: ClaudeDiscoveryHookTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("askkey")
            process.arguments = ["hook", "claude"]
            let environment = helperTestEnvironment(overrides: ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path])
            _ = try DebugRunDirectory.resolve(environment: environment, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = error
            let exited = XCTestExpectation(description: "Claude hook exited")
            process.terminationHandler = { _ in exited.fulfill() }
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.close()
            XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 3), .completed)
            guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
            return output.fileHandleForReading.readDataToEndOfFile()
        }
    }
}
