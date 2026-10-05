import Foundation
import XCTest
@testable import AskKeyBroker

final class CodexCommandDiscoveryHookTests: XCTestCase {
    func testBoundedMultilineDocumentDeniesSSHWithoutRunningToolInput() throws {
        let fixture = try Fixture()
        let marker = fixture.root.appendingPathComponent("must-not-exist")
        let envelope = fixture.envelope("PreToolUse", command: "ssh example.invalid; touch '\(marker.path)'")
        let output = try fixture.call(JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted]))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let specific = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertTrue((specific["permissionDecisionReason"] as? String ?? "").contains("does not authorize"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let stored = try String(contentsOf: fixture.stateURL, encoding: .utf8)
        for privateInput in ["synthetic-session", "synthetic-turn", "example.invalid", marker.path] {
            XCTAssertFalse(stored.contains(privateInput))
        }
    }

    func testOnlyMatchingCatalogPostSettlesTheSameSessionAndTurn() throws {
        let fixture = try Fixture()
        XCTAssertTrue(try fixture.event("PostToolUse", tool: Fixture.catalog, call: "lookup").isEmpty)
        XCTAssertTrue(try fixture.denied())
        XCTAssertTrue(try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lookup").isEmpty)
        XCTAssertTrue(try fixture.denied(), "Scheduling catalog progress is not completion")
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "lookup", session: "other-session")
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "lookup", turn: "other-turn")
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "other-call")
        XCTAssertTrue(try fixture.denied())
        XCTAssertTrue(try fixture.event("PostToolUse", tool: Fixture.catalog, call: "lookup").isEmpty)
        XCTAssertFalse(try fixture.denied())
        XCTAssertTrue(try fixture.denied(turn: "next-turn"))
        XCTAssertTrue(try fixture.denied(session: "other-session"))
    }

    func testLateCallbackCannotSettleANewerTurnWithTheSameCallID() throws {
        let fixture = try Fixture()
        _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lookup", turn: "old-turn")
        _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lookup", turn: "next-turn")
        _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "lookup", turn: "old-turn")
        XCTAssertTrue(try fixture.denied(turn: "next-turn"))
        XCTAssertFalse(try fixture.denied(turn: "old-turn"))
    }

    func testFailedOrMissingCallbackReleasesAfterNoProgressWithoutMarkingCompleted() throws {
        for pending in [false, true] {
            let fixture = try Fixture()
            XCTAssertTrue(try fixture.denied())
            if pending {
                _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "lost")
                // 0.160.0 has no failure callback; this unknown event is ignored.
                _ = try fixture.event("PostToolUseFailure", tool: Fixture.catalog, call: "lost")
            }
            XCTAssertTrue(try fixture.denied())
            try fixture.ageState()
            _ = try fixture.event("PostToolUse", tool: Fixture.catalog, call: "unmatched")
            XCTAssertFalse(try fixture.denied())
            let state = try fixture.state()
            let turns = try XCTUnwrap(state["turns"] as? [String: [String: Any]])
            XCTAssertTrue(turns.values.allSatisfy { $0["completed"] as? Bool == false })
            _ = try fixture.event("PreToolUse", tool: Fixture.catalog, call: "new-progress")
            XCTAssertTrue(try fixture.denied(), "A new catalog attempt resets the progress deadline")
        }
    }

    func testMalformedOversizedAndUnrelatedInputAllowsWithNoOutputOrState() throws {
        let fixture = try Fixture()
        for raw in ["", "{", "[]", "null", "{}", "{}\n{}"] {
            XCTAssertTrue(try fixture.call(Data(raw.utf8)).isEmpty)
        }
        for key in ["session_id", "turn_id", "tool_use_id", "tool_name", "tool_input", "hook_event_name"] {
            var envelope = fixture.envelope("PreToolUse")
            envelope.removeValue(forKey: key)
            XCTAssertTrue(try fixture.call(JSONSerialization.data(withJSONObject: envelope)).isEmpty)
        }
        for key in ["session_id", "turn_id", "tool_use_id"] {
            for invalid in ["", String(repeating: "x", count: 4097)] {
                var envelope = fixture.envelope("PreToolUse")
                envelope[key] = invalid
                XCTAssertTrue(try fixture.call(JSONSerialization.data(withJSONObject: envelope)).isEmpty)
            }
        }
        var oversized = fixture.envelope("PreToolUse")
        oversized["padding"] = String(repeating: "x", count: BrokerLimits.maximumFrameBytes)
        XCTAssertTrue(try fixture.call(JSONSerialization.data(withJSONObject: oversized)).isEmpty)
        for tool in ["shell", "exec_command", "mcp__other__list_credentials", "Read"] {
            XCTAssertTrue(try fixture.event("PreToolUse", tool: tool).isEmpty)
        }
        for command in ["ls", "ssh -V", "ssh -G example.invalid", "echo ssh example.invalid"] {
            XCTAssertTrue(try fixture.event("PreToolUse", command: command).isEmpty)
        }
        for event in ["UserPromptSubmit", "PostToolUseFailure", "SessionStart", "unknown", "PostToolUse"] {
            XCTAssertTrue(try fixture.event(event).isEmpty)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    func testHookCapabilitiesAdvertiseCodexWithoutContactingBroker() throws {
        let fixture = try Fixture()
        let output = try fixture.call(Data(), arguments: ["hook", "capabilities"])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        XCTAssertEqual(response["protocolVersion"] as? Int, 1)
        XCTAssertEqual(Set(try XCTUnwrap(response["clients"] as? [String])), ["cursor", "grok", "claude", "codex"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.stateURL.path))
    }

    private final class Fixture {
        static let catalog = "mcp__askkey__list_credentials"
        let root: URL
        var stateURL: URL { root.appendingPathComponent("credential-discovery/state.json") }
        init() throws {
            let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("askkey-codex-hook-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            root = try physicalTestDirectory(candidate)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func envelope(_ phase: String, tool: String = "Bash", call: String = "ssh",
                      session: String = "synthetic-session", turn: String = "synthetic-turn",
                      command: String = "ssh example.invalid uptime") -> [String: Any] {
            ["hook_event_name": phase, "session_id": session, "turn_id": turn, "tool_name": tool,
             "tool_use_id": call, "tool_input": ["command": command], "tool_response": [:]]
        }
        func event(_ phase: String, tool: String = "Bash", call: String = "ssh",
                   session: String = "synthetic-session", turn: String = "synthetic-turn",
                   command: String = "ssh example.invalid uptime") throws -> [String: Any] {
            let data = try self.call(JSONSerialization.data(withJSONObject:
                envelope(phase, tool: tool, call: call, session: session, turn: turn, command: command)))
            if data.isEmpty { return [:] }
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertFalse(response.isEmpty, "Allowed Codex hooks must emit no output")
            return response
        }
        func denied(session: String = "synthetic-session", turn: String = "synthetic-turn") throws -> Bool {
            (try event("PreToolUse", session: session, turn: turn)["hookSpecificOutput"] as? [String: Any])?["permissionDecision"] as? String == "deny"
        }
        func state() throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        }
        func ageState() throws {
            var state = try state()
            var turns = try XCTUnwrap(state["turns"] as? [String: [String: Any]])
            for key in turns.keys { turns[key]?["touched"] = Date().timeIntervalSince1970 - 31 }
            state["turns"] = turns
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        }
        func call(_ data: Data, arguments: [String] = ["hook", "codex"]) throws -> Data {
            let process = Process()
            process.executableURL = Bundle(for: CodexCommandDiscoveryHookTests.self).bundleURL
                .deletingLastPathComponent().appendingPathComponent("askkey")
            process.arguments = arguments
            let environment = helperTestEnvironment(overrides: ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path])
            _ = try DebugRunDirectory.resolve(environment: environment, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
            process.environment = environment
            let input = Pipe(), output = Pipe(), error = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = error
            let exited = XCTestExpectation(description: "Codex hook exited")
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
