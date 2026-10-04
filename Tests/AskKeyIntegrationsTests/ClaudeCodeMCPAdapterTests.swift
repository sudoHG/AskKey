import Foundation
import XCTest
import AskKeyBroker
import AskKeySystem
@testable import AskKeyIntegrations

final class ClaudeCodeMCPAdapterTests: XCTestCase {
    func testAbsentAddsExactJSONAndVerifiesHelperAndBroker() throws {
        let fixture = try ClaudeCodeMCPFixture()
        let adapter = fixture.adapter()
        let version = try adapter.runClaude(["--version"])
        XCTAssertEqual(version.status, 0, String(decoding: version.stderr, as: UTF8.self))
        XCTAssertEqual(String(decoding: version.stdout, as: UTF8.self), "2.1.282 (Claude Code)")
        XCTAssertEqual(try adapter.plan(), .init(version: "2.1.282", state: .absent))
        XCTAssertTrue(fixture.mutations.isEmpty)
        let result = try adapter.connect()
        XCTAssertTrue(result.connected)
        XCTAssertEqual(result.version, "2.1.282")
        XCTAssertEqual(result.helperVersion, AskKeyVersion.current)
        XCTAssertEqual(fixture.mutations, ["add"])
        let json = try JSONSerialization.jsonObject(with: Data(fixture.read("added-json").utf8)) as? NSDictionary
        XCTAssertEqual(json, ["type": "stdio", "command": fixture.helper.path, "args": ["mcp"]] as NSDictionary)
        let requests = try fixture.read("requests").split(whereSeparator: \.isNewline)
        XCTAssertEqual(requests.count, 2)
        let initialize = try JSONSerialization.jsonObject(with: Data(requests[0].utf8)) as? [String: Any]
        XCTAssertEqual(initialize?["method"] as? String, "initialize")
        let params = initialize?["params"] as? [String: Any]
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["name"] as? String, "claude-code")
        XCTAssertEqual(try fixture.read("helper-calls"), "mcp\nhealth\n")
    }

    func testMatchingConfigurationIsVerifiedWithoutWriting() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("state", "matching")
        XCTAssertEqual(try fixture.adapter().plan().state, .matching)
        XCTAssertTrue(try fixture.adapter().connect().connected)
        XCTAssertTrue(fixture.mutations.isEmpty)
    }

    func testDifferentConfigurationIsUntouched() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("state", "different")
        XCTAssertEqual(try fixture.adapter().plan().state, .different)
        XCTAssertThrowsError(try fixture.adapter().connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .conflictingEntry) }
        XCTAssertTrue(fixture.mutations.isEmpty)
        XCTAssertEqual(try fixture.read("state"), "different")
    }

    func testOtherScopesAreConflictsWithoutWriting() throws {
        for scope in ["project", "local"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("state", scope)
            XCTAssertEqual(try fixture.adapter().plan().state, .scopeConflict)
            XCTAssertThrowsError(try fixture.adapter().connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .conflictingScope) }
            XCTAssertTrue(fixture.mutations.isEmpty)
            XCTAssertEqual(try fixture.read("state"), scope)
        }
    }

    func testFailedAddDoesNotClaimOwnershipOrRemoveAnything() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "add-fail")
        XCTAssertThrowsError(try fixture.adapter().connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .addFailed) }
        XCTAssertEqual(fixture.mutations, ["add"])
        XCTAssertEqual(try fixture.read("state"), "absent")
    }

    func testVerificationFailureRollsBackAndConfirmsAbsence() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "disconnected")
        XCTAssertThrowsError(try fixture.adapter().connect()) {
            XCTAssertEqual($0 as? ClaudeCodeMCPError, .verificationFailed("client_disconnected"))
        }
        XCTAssertEqual(fixture.mutations, ["add", "remove"])
        XCTAssertEqual(try fixture.read("state"), "absent")
        XCTAssertEqual(try fixture.adapter().plan().state, .absent)
    }

    func testRollbackFailureReportsBothFailures() throws {
        for mode in ["rollback-fail", "rollback-retained"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("mode", mode)
            XCTAssertThrowsError(try fixture.adapter().connect()) {
                guard case .rollbackFailed(let original, let cleanup) = $0 as? ClaudeCodeMCPError else {
                    return XCTFail("Expected rollback failure, got \($0)")
                }
                XCTAssertTrue(original.contains("client_disconnected"))
                XCTAssertTrue(cleanup.contains("rollback_absence"))
            }
            XCTAssertEqual(fixture.mutations, ["add", "remove"])
            XCTAssertEqual(try fixture.read("state"), "matching")
        }
    }

    func testConcurrentReplacementIsNeverRemoved() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "concurrent-change")
        XCTAssertThrowsError(try fixture.adapter().connect()) {
            guard case .rollbackFailed(_, let cleanup) = $0 as? ClaudeCodeMCPError else {
                return XCTFail("Expected rollback failure, got \($0)")
            }
            XCTAssertTrue(cleanup.contains("configurationChanged"))
        }
        XCTAssertEqual(fixture.mutations, ["add"])
        XCTAssertEqual(try fixture.read("state"), "different")
    }

    func testUnsupportedAndUnknownVersionsStopBeforeWriting() throws {
        for version in ["2.0.99 (Claude Code)", "1.9.0 (Claude Code)", "unknown", "2.1.0-beta (Claude Code)"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("version", version)
            XCTAssertThrowsError(try fixture.adapter().connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .unsupportedVersion) }
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testMinimumVersionAndNewerVersionsPassCapabilityChecks() throws {
        for version in [ClaudeCodeMCPAdapter.minimumVersion, "2.10.0"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("version", "\(version) (Claude Code)")
            XCTAssertEqual(try fixture.adapter().plan().version, version)
        }
    }

    func testMissingCommandsOrScopeSupportStopBeforeWriting() throws {
        for mode in ["unsupported", "no-scope", "no-remove", "no-get", "no-list"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("mode", mode)
            XCTAssertThrowsError(try fixture.adapter().connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .unsupportedCLI) }
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testUnknownCLIResponsesCannotAuthorizeAnAdd() throws {
        for mode in ["get-fail", "list-fail", "list-conflict", "unreadable"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("mode", mode)
            if mode == "unreadable" { try fixture.write("state", "matching") }
            XCTAssertThrowsError(try fixture.adapter().connect()) {
                XCTAssertEqual($0 as? ClaudeCodeMCPError, .unreadableConfiguration)
            }
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testUnrelatedListedServerDoesNotConflict() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "unrelated-server")
        XCTAssertTrue(try fixture.adapter().connect().connected)
        XCTAssertEqual(fixture.mutations, ["add"])
    }

    func testExtraEnvironmentArgumentsAndDuplicateFieldsAreNotMatching() throws {
        for mode in ["extra-env", "duplicate-command", "extra-args"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("state", "matching")
            try fixture.write("mode", mode)
            XCTAssertEqual(try fixture.adapter().plan().state, .different)
            XCTAssertThrowsError(try fixture.adapter().connect())
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testDisconnectedExistingEntryIsNotRemoved() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("state", "matching")
        try fixture.write("mode", "disconnected")
        XCTAssertFalse(try fixture.adapter().connect().connected)
        XCTAssertTrue(fixture.mutations.isEmpty)
    }

    func testHelperSignatureContractAndBrokerAreRequired() throws {
        for mode in ["malformed", "nonzero", "unhealthy", "untrusted"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("state", "matching")
            try fixture.write("helper-mode", mode)
            let adapter = fixture.adapter(signing: mode == "untrusted" ? .init { _ in false } : .development)
            let status = try adapter.verify()
            XCTAssertFalse(status.connected)
            XCTAssertEqual(status.reason, mode == "untrusted" ? "helper_signature" : mode == "unhealthy" ? "broker_unhealthy" : "helper_contract")
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testCancellationAfterAddRollsBackDespiteCancelledContext() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "cancel-after-add")
        let cancelled = fixture.home.appendingPathComponent("cancelled")
        XCTAssertThrowsError(try RestrictedProcessCancellation.withValue({
            FileManager.default.fileExists(atPath: cancelled.path)
        }) { try fixture.adapter().connect() }) {
            XCTAssertEqual($0 as? ClaudeCodeMCPError, .cancelled)
        }
        XCTAssertEqual(fixture.mutations, ["add", "remove"])
        XCTAssertEqual(try fixture.read("state"), "absent")
    }

    func testCancellationDuringReadStopsWithoutWriting() throws {
        let fixture = try ClaudeCodeMCPFixture()
        try fixture.write("mode", "sleep")
        let deadline = ProcessInfo.processInfo.systemUptime + 0.15
        XCTAssertThrowsError(try RestrictedProcessCancellation.withValue({
            ProcessInfo.processInfo.systemUptime >= deadline
        }) { try fixture.adapter().connect() }) {
            XCTAssertEqual($0 as? ClaudeCodeMCPError, .cancelled)
        }
        XCTAssertTrue(fixture.mutations.isEmpty)
    }

    func testTimeoutAndOutputOverflowStopBeforeWriting() throws {
        for mode in ["sleep", "flood"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("mode", mode)
            var adapter = fixture.adapter()
            adapter.commandTimeout = mode == "sleep" ? 0.1 : 3
            XCTAssertThrowsError(try adapter.connect()) {
                XCTAssertEqual($0 as? ClaudeCodeMCPError, mode == "sleep" ? .timeout : .outputTooLarge)
            }
            XCTAssertTrue(fixture.mutations.isEmpty)
        }
    }

    func testSyntheticSettingsAndOtherConfigurationArePreserved() throws {
        let fixture = try ClaudeCodeMCPFixture()
        let settings = fixture.home.appendingPathComponent(".claude/settings.json")
        let configuration = fixture.home.appendingPathComponent(".claude.json")
        let unrelated = Data("{\"syntheticOtherServer\":\"preserve\"}".utf8)
        let hooks = Data("{\"hooks\":{\"syntheticEvent\":[]},\"permissions\":{\"allow\":[]}}".utf8)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try unrelated.write(to: configuration)
        try hooks.write(to: settings)
        XCTAssertTrue(try fixture.adapter().connect().connected)
        XCTAssertEqual(try Data(contentsOf: configuration), unrelated)
        XCTAssertEqual(try Data(contentsOf: settings), hooks)
    }

    func testUserPATHResolutionAndMissingExecutable() throws {
        let fixture = try ClaudeCodeMCPFixture()
        // The executable lives in the supplied synthetic user's .local/bin.
        XCTAssertEqual(fixture.adapter().claudeExecutable, fixture.executable)
        try FileManager.default.removeItem(at: fixture.executable)
        let adapter = ClaudeCodeMCPAdapter(
            homeDirectory: fixture.home, workingDirectory: fixture.project, helperURL: fixture.helper,
            brokerSocketPath: "synthetic", claudeExecutable: fixture.executable
        )
        XCTAssertThrowsError(try adapter.connect()) { XCTAssertEqual($0 as? ClaudeCodeMCPError, .missingExecutable) }
        XCTAssertTrue(fixture.mutations.isEmpty)
    }

    func testHelperVerificationFailureRollsBackNewEntry() throws {
        for mode in ["malformed", "unhealthy"] {
            let fixture = try ClaudeCodeMCPFixture()
            try fixture.write("helper-mode", mode)
            XCTAssertThrowsError(try fixture.adapter().connect()) {
                XCTAssertEqual($0 as? ClaudeCodeMCPError, .verificationFailed(mode == "malformed" ? "helper_contract" : "broker_unhealthy"))
            }
            XCTAssertEqual(fixture.mutations, ["add", "remove"])
            XCTAssertEqual(try fixture.read("state"), "absent")
        }
    }
}
