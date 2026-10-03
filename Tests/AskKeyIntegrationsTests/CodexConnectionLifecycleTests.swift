import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

final class CodexConnectionLifecycleTests: CodexUserMCPAdapterTests {
    func testDisabledMCPDoesNotReportConnectedEvenWhenTheHelperWorks() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        let config = try harness.configText() + "enabled = false\n"
        try harness.writeConfig(config, mode: 0o600)
        XCTAssertEqual(harness.adapter.status(), .notConnected)
        XCTAssertEqual(try harness.configText(), config)
    }
    func testDiscoverySetupRejectsALegacyHelperWithoutTheGuardTool() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("askkey")
        let script = """
        #!/bin/sh
        cat >/dev/null
        cat <<'RESPONSE'
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"0.1.0"}}}
        {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
        RESPONSE
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let harness = try makeHarness(helperOverride: helper)
        _ = try harness.adapter.apply()
        XCTAssertEqual(harness.adapter.status(), .connected)
        let discovery = CodexUserMCPAdapter(
            configURL: harness.configURL, helperURL: helper, backupDirectory: harness.backupDirectory,
            brokerSocketPath: harness.socketPath, signing: .development, requiresCredentialDiscovery: true
        )
        XCTAssertEqual(discovery.status(), .notConnected)
    }
    func testEmptyConfigWritesAskKeyAndConnectsThroughHelperAndBroker() throws {
        let harness = try makeHarness()
        let result = try harness.adapter.apply()

        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(try harness.configMode(), 0o600)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
        XCTAssertTrue(try harness.configText().contains("command = \"\(harness.helperURL.path)\""))
        XCTAssertTrue(try harness.configText().contains("args = [\"mcp\"]"))
        XCTAssertFalse(harness.backupExists)
        XCTAssertFalse(harness.wroteProjectConfig)
        XCTAssertEqual(harness.adapter.status(), .connected)
    }
    func testComplexTOMLKeepsCommentsOtherServersAndMode() throws {
        let harness = try makeHarness()
        let original = """
        # keep this comment
        model = "gpt-5"

        [projects."/tmp/trusted-project"]
        trust_level = "trusted"

        [mcp_servers.github]
        command = "npx"
        args = ["-y", "github"]

        [mcp_servers.github.env]
        GITHUB_TOKEN = "\(Harness.secret)"
        """
        try harness.writeConfig(original, mode: 0o644)
        try harness.writeProjectConfig("project-must-not-change\n")

        let preview = try harness.adapter.preview()
        XCTAssertFalse(preview.redactedDescription.contains(Harness.secret))
        XCTAssertTrue(preview.redactedDescription.contains("***"))

        XCTAssertEqual(try harness.adapter.apply().status, .connected)

        let after = try harness.configText()
        XCTAssertTrue(after.contains("# keep this comment"))
        XCTAssertTrue(after.contains("model = \"gpt-5\""))
        XCTAssertTrue(after.contains("[projects.\"/tmp/trusted-project\"]"))
        XCTAssertTrue(after.contains("[mcp_servers.github]"))
        XCTAssertTrue(after.contains("GITHUB_TOKEN = \"\(Harness.secret)\""))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
        XCTAssertTrue(after.contains("command = \"\(harness.helperURL.path)\""))
        XCTAssertEqual(try harness.configMode(), 0o644)
        XCTAssertEqual(try harness.projectConfigText(), "project-must-not-change\n")
        XCTAssertFalse(harness.wroteHomeCodex)
    }
    func testIllegalConfigAndUnsafeFilesFailClosed() throws {
        let illegal = try makeHarness()
        try illegal.writeConfig("{ this is not toml\n[[[", mode: 0o600)
        XCTAssertThrowsError(try illegal.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig)
        }
        XCTAssertEqual(try illegal.configText(), "{ this is not toml\n[[[")

        let link = try makeHarness()
        let target = link.root.appendingPathComponent("real.toml")
        try Data("model = \"ok\"\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link.configURL, withDestinationURL: target)
        XCTAssertThrowsError(try link.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .unsafeConfigFile)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "model = \"ok\"\n")

        let fifo = try makeHarness()
        XCTAssertEqual(mkfifo(fifo.configURL.path, 0o600), 0)
        XCTAssertThrowsError(try fifo.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .unsafeConfigFile)
        }
    }
    func testUnknownCodexVersionFailsClosed() throws {
        let harness = try makeHarness(cli: .unknown("nightly-mystery"))
        try harness.writeConfig("model = \"keep\"\n", mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .unknownCodexVersion)
        }
        XCTAssertEqual(try harness.configText(), "model = \"keep\"\n")
        XCTAssertFalse(harness.cli.addCalled)
        XCTAssertFalse(harness.backupExists)
    }
    func testSupportedOfficialCLIIsTriedThenCommentsArePreserved() throws {
        let harness = try makeHarness(cli: .supported("0.42.0", rewriteWithoutComments: true))
        try harness.writeConfig("""
        # keep
        [mcp_servers.other]
        command = "echo"
        """, mode: 0o600)

        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertTrue(harness.cli.addCalled)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("# keep"))
        XCTAssertTrue(after.contains("[mcp_servers.other]"))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
    }
    func testMissingOfficialCLIUsesLosslessTOML() throws {
        let harness = try makeHarness(cli: .missing)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertFalse(harness.cli.addCalled)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
    }
    func testBackupPermissionsRollbackAndSuccessfulDelete() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        harness.adapter.lifecycle.afterWrite = { throw CodexUserMCPError.connectionFailed("interrupted") }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .connectionFailed("interrupted"))
        }
        XCTAssertEqual(try harness.configText(), "model = \"original\"\n")
        XCTAssertEqual(try harness.configMode(), 0o640)
        XCTAssertFalse(harness.backupExists)

        harness.adapter.lifecycle.afterWrite = {}
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertFalse(harness.backupExists)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
        XCTAssertEqual(try harness.configMode(), 0o640)
    }
    func testRollbackFailureIsVisibleAndKeepsTheBackup() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        harness.adapter.lifecycle.afterWrite = {
            throw CodexUserMCPError.connectionFailed("verification")
        }
        harness.adapter.lifecycle.beforeRestore = {
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertTrue(harness.backupExists)
    }
    func testBackupCleanupFailureDuringRollbackIsVisible() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        defer { try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: harness.backupDirectory.path
        ) }
        harness.adapter.lifecycle.afterWrite = {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: harness.backupDirectory.path
            )
            throw CodexUserMCPError.connectionFailed("verification")
        }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try harness.configText(), "model = \"original\"\n")
        XCTAssertTrue(harness.backupExists)
    }
    func testExternalRewriteAfterApplyIsPreservedWhenVerificationFails() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        let concurrent = "model = \"concurrent\"\n"
        harness.adapter.lifecycle.afterWrite = {
            try harness.writeConfig(concurrent, mode: 0o600)
            throw CodexUserMCPError.connectionFailed("verification")
        }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try harness.configText(), concurrent)
        XCTAssertTrue(harness.backupExists)

        harness.adapter.lifecycle.afterWrite = {
            throw CodexUserMCPError.connectionFailed("verification")
        }
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(
                error as? CodexUserMCPError,
                .connectionFailed("verification")
            )
        }
        XCTAssertEqual(try harness.configText(), concurrent)
    }
    func testExternalDeleteAfterApplyIsNotRecreatedByRollback() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        harness.adapter.lifecycle.afterWrite = {
            try FileManager.default.removeItem(at: harness.configURL)
            throw CodexUserMCPError.connectionFailed("verification")
        }
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path))
    }
    func testBackupIsSingle07000600CopyDuringApply() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o644)
        var sawBackup = false
        harness.adapter.lifecycle.afterBackup = {
            sawBackup = true
            XCTAssertEqual(try harness.backupMode(), 0o600)
            XCTAssertEqual(try harness.backupDirectoryMode(), 0o700)
            XCTAssertEqual(try harness.backupText(), "model = \"original\"\n")
            XCTAssertEqual(harness.backupFileCount, 1)
            XCTAssertEqual(
                try harness.backupDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true
            )
        }
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertTrue(sawBackup)
        XCTAssertFalse(harness.backupExists)
    }
    func testProtocolFailureRollsBackAndIsNotConnected() throws {
        let harness = try makeHarness(helperOverride: URL(fileURLWithPath: "/usr/bin/true"))
        try harness.writeConfig("model = \"keep\"\n", mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .connectionFailed("protocol"))
        }
        XCTAssertEqual(try harness.configText(), "model = \"keep\"\n")
        XCTAssertNotEqual(harness.adapter.status(), .connected)
        XCTAssertFalse(harness.backupExists)
    }
    func testStatusReturnsWhenHelperIgnoresTermination() throws {
        let helper = try makeIgnoringTerminationExecutable()
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let harness = try makeHarness(helperOverride: helper)
        try harness.writeConfig("""
        [mcp_servers.askkey]
        command = "\(helper.path)"
        args = ["mcp"]
        """, mode: 0o600)

        let started = Date()
        XCTAssertEqual(harness.adapter.status(), .notConnected)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testCLIStatusReturnsWhenCodexIgnoresTermination() throws {
        let executable = try makeIgnoringTerminationExecutable()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessCodexMCPCommand.make(executable: executable)

        let started = Date()
        guard case .unknown = command.status() else {
            return XCTFail("A timed-out Codex process must not be treated as supported")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
    func testApplyRollsBackWhenBrokerHealthFailsAndStatusIsNotConnected() throws {
        let harness = try makeHarness(brokerHealth: "down")
        try harness.writeConfig("model = \"keep\"\n", mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .connectionFailed("broker"))
        }
        XCTAssertEqual(try harness.configText(), "model = \"keep\"\n")
        XCTAssertNotEqual(harness.adapter.status(), .connected)
    }
    func testExistingConfigDoesNotCountAsConnectedWhenHelperOrBrokerFails() throws {
        let harness = try makeHarness()
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        harness.stopBroker()
        XCTAssertNotEqual(harness.adapter.status(), .connected)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
    }
    func testUntrustedHelperDoesNotReportConnected() throws {
        let harness = try makeHarness(trustHelper: false)
        try harness.writeConfig("""
        [mcp_servers.askkey]
        command = "/tmp/not-askkey"
        args = ["mcp"]
        """, mode: 0o600)
        XCTAssertNotEqual(harness.adapter.status(), .connected)
        XCTAssertThrowsError(try harness.adapter.apply())
        XCTAssertTrue(try harness.configText().contains("not-askkey"))
    }
    func testConcurrentApplyDoesNotOverlapBackupMutation() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o600)
        let state = NSLock()
        var inflight = 0
        var maxInflight = 0
        harness.adapter.lifecycle.afterBackup = {
            state.lock()
            inflight += 1
            maxInflight = max(maxInflight, inflight)
            state.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            state.lock()
            inflight -= 1
            state.unlock()
        }
        let done = expectation(description: "both applies finished")
        done.expectedFulfillmentCount = 2
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? harness.adapter.apply()
            done.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? harness.adapter.apply()
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(maxInflight, 1)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
        XCTAssertFalse(harness.backupExists)
    }
}
