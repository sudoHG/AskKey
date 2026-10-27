import Foundation
import XCTest
@testable import AskKeyIntegrations

final class ClaudeCodeMCPTimeoutTests: XCTestCase {
    func testWriteThenTimeoutReportsWrittenWithoutRetryOrRollback() throws {
        try assertTimeout(mode: "timeout-written", expected: .written, state: "matching")
    }

    func testWrittenDisconnectedEntryIsNotClaimedAsVerifiedOrRemoved() throws {
        try assertTimeout(mode: "timeout-disconnected", expected: .written, state: "matching")
    }

    func testTimeoutWithoutWriteConfirmsAbsence() throws {
        try assertTimeout(mode: "timeout-not-written", expected: .notWritten, state: "absent")
    }

    func testConcurrentReplacementOrScopeChangeIsUncertainAndPreserved() throws {
        try assertTimeout(mode: "timeout-different", expected: .uncertain, state: "different")
        try assertTimeout(mode: "timeout-project", expected: .uncertain, state: "project")
    }

    func testUnreadableOrFailedReinspectionIsUncertain() throws {
        try assertTimeout(mode: "timeout-unreadable", expected: .uncertain, state: "matching")
        try assertTimeout(mode: "timeout-read-fail", expected: .uncertain, state: "matching")
    }

    func testReinspectionTimeoutIsBoundedAndUncertain() throws {
        let start = ProcessInfo.processInfo.systemUptime
        try assertTimeout(mode: "timeout-read-timeout", expected: .uncertain, state: "matching")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
    }

    private func assertTimeout(
        mode: String, expected: ClaudeCodeMCPWriteOutcome, state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", mode)
        var adapter = fixture.adapter()
        adapter.commandTimeout = 0.3
        XCTAssertThrowsError(try adapter.connect(), file: file, line: line) {
            XCTAssertEqual($0 as? ClaudeCodeMCPError, .writeTimedOut(expected), file: file, line: line)
        }
        XCTAssertEqual(fixture.mutations, ["add"], file: file, line: line)
        XCTAssertEqual(try fixture.read("state"), state, file: file, line: line)
        let calls = try fixture.read("calls").split(whereSeparator: \.isNewline)
        XCTAssertEqual(calls.filter { $0 == "mcp get askkey" }.count, 3, file: file, line: line)
        XCTAssertEqual(calls.last, "mcp get askkey", file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("helper-calls").path))
        let configuration = fixture.home.appendingPathComponent(".claude.json")
        if state == "absent" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.path))
        } else {
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any])
            let servers = try XCTUnwrap(document["mcpServers"] as? [String: [String: Any]])
            XCTAssertEqual(servers["askkey"]?["command"] as? String,
                state == "different" ? "/synthetic/other-helper" : fixture.helper.path)
            XCTAssertEqual(servers["askkey"]?["args"] as? [String], ["mcp"])
        }
    }
}
