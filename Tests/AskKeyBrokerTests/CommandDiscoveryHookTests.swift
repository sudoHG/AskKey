import Darwin
import Foundation
import XCTest
@testable import AskKeyBroker

final class CommandDiscoveryHookTests: XCTestCase {
    func testCursorCommandHookPausesSSHBeforeCatalogLookup() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let result = try fixture.call("cursor", [
            "hook_event_name": "preToolUse", "conversation_id": "session-a",
            "generation_id": "turn-a", "tool_use_id": "ssh-a", "tool_name": "Shell",
            "tool_input": ["command": "ssh example.invalid uptime"],
        ])
        XCTAssertEqual(result["permission"] as? String, "deny")
        XCTAssertTrue((result["agent_message"] as? String ?? "").contains("list_credentials"))
    }

    func testCursorSeparateProcessesReleaseOnlyTheCompletedCatalogTurn() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        func event(_ phase: String, _ tool: String, _ call: String, turn: String = "turn-a",
                   session: String = "session-a") -> [String: Any] {
            ["hook_event_name": phase, "conversation_id": session, "generation_id": turn,
             "tool_use_id": call, "tool_name": tool,
             "tool_input": ["command": "ssh example.invalid uptime"]]
        }
        let catalog = "MCP:list_credentials"
        _ = try fixture.call("cursor", event("preToolUse", catalog, "lookup-a"))
        XCTAssertEqual(try fixture.call("cursor", event("preToolUse", "Shell", "ssh-a"))["permission"] as? String, "deny")
        _ = try fixture.call("cursor", event("postToolUse", catalog, "lookup-other", session: "session-other"))
        XCTAssertEqual(try fixture.call("cursor", event("preToolUse", "Shell", "ssh-a"))["permission"] as? String, "deny")
        _ = try fixture.call("cursor", event("postToolUse", catalog, "lookup-a"))
        XCTAssertEqual(try fixture.call("cursor", event("preToolUse", "Shell", "ssh-a"))["permission"] as? String, "allow")
        XCTAssertEqual(try fixture.call("cursor", event("preToolUse", "Shell", "ssh-b", turn: "turn-b"))["permission"] as? String, "deny")
    }

    func testGrokNativeEventsKeepLateCatalogResultInItsOriginalTurn() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        func prompt(_ id: String) throws {
            _ = try fixture.call("grok", ["hookEventName": "user_prompt_submit",
                "sessionId": "grok-session", "promptId": id])
        }
        func event(_ phase: String, _ tool: String, _ id: String) -> [String: Any] {
            ["hookEventName": phase, "sessionId": "grok-session", "toolUseId": id,
             "toolName": tool, "toolInput": ["command": "ssh example.invalid uptime"]]
        }
        func denied() throws -> Bool {
            let reply = try fixture.call("grok", event("pre_tool_use", "run_terminal_command", "ssh"))
            return (reply["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "deny"
        }
        try prompt("old")
        XCTAssertTrue(try denied())
        _ = try fixture.call("grok", event("pre_tool_use", "askkey__list_credentials", "old-lookup"))
        try prompt("new")
        _ = try fixture.call("grok", event("post_tool_use", "askkey__list_credentials", "old-lookup"))
        XCTAssertTrue(try denied(), "Old completion cannot release a newer turn")
        _ = try fixture.call("grok", event("pre_tool_use", "askkey__list_credentials", "new-lookup"))
        XCTAssertTrue(try denied(), "Merely scheduling a catalog cannot release SSH")
        _ = try fixture.call("grok", event("post_tool_use_failure", "askkey__list_credentials", "new-lookup"))
        XCTAssertFalse(try denied(), "A completed unavailable-catalog attempt must not loop forever")
        try prompt("third")
        XCTAssertTrue(try denied())
    }

    func testCursorDefinitionImportedByGrokDoesNotDuplicateItsNativeGuard() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let event: [String: Any] = ["hookEventName": "pre_tool_use", "hook_event_name": "PreToolUse",
            "sessionId": "grok-session", "session_id": "grok-session", "toolUseId": "ssh",
            "toolName": "run_terminal_command", "toolInput": ["command": "ssh example.invalid uptime"]]
        XCTAssertEqual(try fixture.call("cursor", event)["permission"] as? String, "allow")
        let native = try fixture.call("grok", event)
        XCTAssertEqual((native["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String, "deny")
    }

    func testUnsafeStateSymlinkCannotOverwriteAnotherFile() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let elsewhere = fixture.root.appendingPathComponent("keep.txt")
        try Data("keep unchanged".utf8).write(to: elsewhere)
        let state = fixture.root.appendingPathComponent("credential-discovery")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("state.json"), withDestinationURL: elsewhere)
        let reply = try fixture.call("cursor", ["hook_event_name": "preToolUse",
            "conversation_id": "session", "generation_id": "turn", "tool_use_id": "ssh",
            "tool_name": "Shell", "tool_input": ["command": "ssh example.invalid uptime"]])
        XCTAssertEqual(reply["permission"] as? String, "allow")
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "keep unchanged")
    }

    func testNonConnectionCommandsDoNotCreateDiscoveryState() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for command in ["ls", "ssh -G example.invalid", "ssh -V", "echo ssh example.invalid"] {
            let reply = try fixture.call("cursor", ["hook_event_name": "preToolUse",
                "conversation_id": "session", "generation_id": "turn", "tool_name": "Shell",
                "tool_input": ["command": command]])
            XCTAssertEqual(reply["permission"] as? String, "allow")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            fixture.root.appendingPathComponent("credential-discovery").path))
    }

    func testLostCatalogCallbackCannotBlockTheTurnIndefinitely() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        _ = try fixture.call("cursor", ["hook_event_name": "preToolUse",
            "conversation_id": "session", "generation_id": "turn", "tool_use_id": "lookup",
            "tool_name": "MCP:list_credentials", "tool_input": [:]])
        // Simulate a completed call whose callback was lost, with its pending
        // record left behind for a minute. No real clock delay is needed.
        try fixture.ageState()
        let reply = try fixture.call("cursor", ["hook_event_name": "preToolUse",
            "conversation_id": "session", "generation_id": "turn", "tool_use_id": "ssh",
            "tool_name": "Shell", "tool_input": ["command": "ssh example.invalid uptime"]])
        XCTAssertEqual(reply["permission"] as? String, "allow")
    }

    func testUnavailableCatalogCannotLeaveTheReminderPermanentlyBlocked() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let event: [String: Any] = ["hook_event_name": "preToolUse",
            "conversation_id": "session", "generation_id": "turn", "tool_use_id": "ssh",
            "tool_name": "Shell", "tool_input": ["command": "ssh example.invalid uptime"]]
        XCTAssertEqual(try fixture.call("cursor", event)["permission"] as? String, "deny")
        try fixture.ageState()
        XCTAssertEqual(try fixture.call("cursor", event)["permission"] as? String, "allow")
    }

    private final class Fixture {
        let root: URL
        init() throws {
            let candidate = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("askkey-command-hook-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            // Foundation rewrites /private/tmp to the /tmp symlink on macOS;
            // DebugRunDirectory intentionally requires literal non-link paths.
            root = candidate
        }
        func close() { try? FileManager.default.removeItem(at: root) }
        func ageState() throws {
            let path = root.appendingPathComponent("credential-discovery/state.json")
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            var turns = try XCTUnwrap(state["turns"] as? [String: [String: Any]])
            for key in Array(turns.keys) { turns[key]?["touched"] = Date().timeIntervalSince1970 - 60 }
            state["turns"] = turns
            try JSONSerialization.data(withJSONObject: state).write(to: path)
        }
        func call(_ client: String, _ event: [String: Any]) throws -> [String: Any] {
            let executable = Bundle(for: CommandDiscoveryHookTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("askkey")
            let process = Process()
            process.executableURL = executable
            process.arguments = ["hook", client]
            var environment = ProcessInfo.processInfo.environment
            environment["ASKKEY_DEBUG_RUN_DIRECTORY"] = root.path
            environment.removeValue(forKey: "ASKKEY_BROKER_SOCKET")
            _ = try DebugRunDirectory.resolve(environment: environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            process.environment = environment
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { process.terminate() } }
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: event))
            try input.fileHandleForWriting.close()
            let exited = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !process.isRunning }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 3), .completed)
            guard !process.isRunning else { throw CocoaError(.executableRuntimeMismatch) }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            XCTAssertEqual(process.terminationStatus, 0, "Hook must emit a protocol response")
            return try XCTUnwrap(try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
    }
}
