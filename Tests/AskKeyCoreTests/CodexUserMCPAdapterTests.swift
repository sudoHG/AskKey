import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

final class CodexUserMCPAdapterTests: AskKeyCoreTestCase {
    private var harnesses: [Harness] = []

    override func tearDown() {
        for harness in harnesses { harness.close() }
        harnesses.removeAll()
        super.tearDown()
    }

    private func makeHarness(
        cli: FakeCodexCLI.Kind = .missing,
        brokerHealth: String = "ok",
        trustHelper: Bool = true,
        helperOverride: URL? = nil
    ) throws -> Harness {
        let harness = try Harness(cli: cli, brokerHealth: brokerHealth,
                                  trustHelper: trustHelper, helperOverride: helperOverride)
        harnesses.append(harness)
        return harness
    }
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

    func testCurrentVerifiedCodexVersionSupportsOfficialMCPCommand() {
        XCTAssertTrue(CodexUserMCP.allowsOfficialCLI("0.151.0"))
        XCTAssertTrue(CodexUserMCP.allowsOfficialCLI("0.153.4"))
        XCTAssertTrue(CodexUserMCP.allowsOfficialCLI("0.154.0"))
        XCTAssertTrue(CodexUserMCP.allowsOfficialCLI("0.154.1"))
        XCTAssertTrue(CodexUserMCP.allowsOfficialCLI("0.156.0"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.152.0"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.155.0"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.157.0"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.151.0-beta"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.154.0-beta.1"))
        XCTAssertFalse(CodexUserMCP.allowsOfficialCLI("0.154.0+build.1"))
    }

    func testCodex153PreviewAndApplyUseVerifiedOfficialContract() throws {
        let harness = try makeHarness(cli: .supported("0.153.4", rewriteWithoutComments: false))
        XCTAssertNoThrow(try harness.adapter.preview())
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertTrue(harness.cli.addCalled)
    }

    func testCodex154ProcessVersionAllowsPreviewAndApply() throws {
        try assertCodexProcessVersionAllowsPreviewAndApply("0.154.0")
    }

    func testCodex156ProcessVersionAllowsPreviewAndApply() throws {
        try assertCodexProcessVersionAllowsPreviewAndApply("0.156.0")
    }

    private func assertCodexProcessVersionAllowsPreviewAndApply(_ version: String) throws {
        let harness = try makeHarness()
        let fixture = try CodexProcessFixture(harness: harness, versionOutput: "codex-cli \(version)")
        let command = ProcessCodexMCPCommand.make(executable: fixture.executable)
        let adapter = harness.makeAdapter(command: command)
        let original = "# preserve\n[mcp_servers.kept]\ncommand = \"/usr/bin/true\"\n"
        try harness.writeConfig(original, mode: 0o640)

        XCTAssertEqual(command.status(), .supported(version: version))
        XCTAssertNoThrow(try adapter.preview())
        XCTAssertEqual(try adapter.apply().status, .connected)
        XCTAssertTrue(try harness.configText().contains(original))
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
        XCTAssertEqual(try harness.configMode(), 0o640)
        XCTAssertFalse(harness.backupExists)
        XCTAssertFalse(harness.wroteHomeCodex)
    }

    func testKnownCLIProcessVersionFormatsRemainSupported() throws {
        for (versionOutput, version) in [
            ("codex-cli 0.42.0", "0.42.0"),
            ("codex-cli 0.153.4\n", "0.153.4"),
            ("0.153.4\n", "0.153.4"),
        ] {
            let harness = try makeHarness()
            let fixture = try CodexProcessFixture(harness: harness, versionOutput: versionOutput)
            let command = ProcessCodexMCPCommand.make(executable: fixture.executable)
            XCTAssertEqual(command.status(), .supported(version: version), versionOutput)
        }
    }

    func testPrereleaseAndUnknownCLIProcessVersionsFailWithoutMutation() throws {
        for versionOutput in [
            "codex-cli 0.153.4-beta.1",
            "codex-cli 0.154.0-beta.1",
            "codex-cli 0.154.0+build.1",
            "codex-cli 0.154.0.1",
            "codex-cli v0.154.0",
            "codex-cli 0.154.0 beta.1",
            "unrecognized-cli 0.154.0",
            "0.154.0-beta.1",
            "codex-cli 0.155.0",
            "codex-cli 0.156.0-beta.1",
            "codex-cli 0.156.0+build.1",
            "codex-cli 0.157.0",
            "codex-cli nightly",
        ] {
            let harness = try makeHarness()
            let fixture = try CodexProcessFixture(harness: harness, versionOutput: versionOutput)
            let command = ProcessCodexMCPCommand.make(executable: fixture.executable)
            let adapter = harness.makeAdapter(command: command)
            let original = "# unchanged\nmodel = \"gpt-5\"\n"
            try harness.writeConfig(original, mode: 0o640)

            switch command.status() {
            case .unknown:
                break
            default:
                XCTFail("Unverified CLI output must be rejected: \(versionOutput)")
            }
            XCTAssertThrowsError(try adapter.preview(), versionOutput) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .unknownCodexVersion)
            }
            XCTAssertThrowsError(try adapter.apply(), versionOutput) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .unknownCodexVersion)
            }
            XCTAssertEqual(try harness.configText(), original, versionOutput)
            XCTAssertEqual(try harness.configMode(), 0o640)
            XCTAssertFalse(FileManager.default.fileExists(atPath: harness.backupDirectory.path))
            XCTAssertFalse(harness.wroteHomeCodex)
        }
    }

    func testCodexMCPAddGetJSONContractUsesIsolatedConfiguration() throws {
        let harness = try makeHarness()
        let fixture = try CodexProcessFixture(harness: harness)
        try assertCodexMCPAddGetJSONContract(executable: fixture.executable,
                                           expectedVersion: "0.154.0", harness: harness)
    }

    func testInstalledCodexMCPAddGetJSONContractUsesIsolatedConfiguration() throws {
        let configuredPath = requestedEnvironmentValue("ASKKEY_TEST_CODEX_EXECUTABLE")
        let configuredVersion = requestedEnvironmentValue("ASKKEY_TEST_CODEX_EXPECTED_VERSION")
        if configuredPath == nil && configuredVersion == nil {
            throw XCTSkip("Set ASKKEY_TEST_CODEX_EXECUTABLE and ASKKEY_TEST_CODEX_EXPECTED_VERSION for the installed CLI contract")
        }
        let path = try XCTUnwrap(configuredPath, "An explicit installed Codex executable is required")
        let version = try XCTUnwrap(configuredVersion, "Pin the expected Codex version; do not infer it from the installed CLI")
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        guard CodexUserMCP.allowsOfficialCLI(version) else {
            return XCTFail("Installed CLI acceptance requires an explicitly supported version: \(version)")
        }
        let executable = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try assertCodexMCPAddGetJSONContract(executable: executable,
                                           expectedVersion: version, harness: Harness())
    }

    private func assertCodexMCPAddGetJSONContract(executable: URL, expectedVersion: String,
                                               harness: Harness) throws {
        let config = harness.root.appendingPathComponent("contract-home/.codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let original = """
        cli_auth_credentials_store = "file"
        mcp_oauth_credentials_store = "file"
        [mcp_servers.kept]
        command = "/usr/bin/true"
        args = []
        """
        try Data(original.utf8).write(to: config)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        let version = try scopedCodexOutput(executable, arguments: ["--version"], config: config)
        let actualVersion = String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualVersion == "codex-cli \(expectedVersion)" else {
            return XCTFail("Codex CLI version changed: expected codex-cli \(expectedVersion), got \(actualVersion)")
        }
        // Exercise the production child-environment isolation directly.
        try ProcessCodexMCPCommand.make(executable: executable).addAskKey(harness.helperURL, config)
        let output = try scopedCodexOutput(executable,
                                          arguments: ["mcp", "get", "askkey", "--json"], config: config)
        let server = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let transport = try XCTUnwrap(server["transport"] as? [String: Any])
        XCTAssertEqual(server["name"] as? String, "askkey")
        XCTAssertEqual(server["enabled"] as? Bool, true)
        XCTAssertEqual(transport["type"] as? String, "stdio")
        XCTAssertEqual(transport["command"] as? String, harness.helperURL.path)
        XCTAssertEqual(transport["args"] as? [String], ["mcp"])
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("[mcp_servers.kept]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.projectConfigURL.path))
        XCTAssertFalse(harness.wroteHomeCodex)
    }

    func testBundledHelperPathUsesCanonicalAppHelperLocation() {
        XCTAssertEqual(
            CodexUserMCP.bundledHelperPath,
            "/Applications/Ask Key.app/Contents/Helpers/askkey"
        )
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
        harness.adapter.probe.afterWrite = { throw CodexUserMCPError.connectionFailed("interrupted") }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .connectionFailed("interrupted"))
        }
        XCTAssertEqual(try harness.configText(), "model = \"original\"\n")
        XCTAssertEqual(try harness.configMode(), 0o640)
        XCTAssertFalse(harness.backupExists)

        harness.adapter.probe.afterWrite = {}
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertFalse(harness.backupExists)
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
        XCTAssertEqual(try harness.configMode(), 0o640)
    }

    func testRollbackFailureIsVisibleAndKeepsTheBackup() throws {
        let harness = try makeHarness()
        try harness.writeConfig("model = \"original\"\n", mode: 0o640)
        harness.adapter.probe.afterWrite = {
            throw CodexUserMCPError.connectionFailed("verification")
        }
        harness.adapter.probe.beforeRestore = {
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
        harness.adapter.probe.afterWrite = {
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
        harness.adapter.probe.afterWrite = {
            try harness.writeConfig(concurrent, mode: 0o600)
            throw CodexUserMCPError.connectionFailed("verification")
        }

        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try harness.configText(), concurrent)
        XCTAssertTrue(harness.backupExists)

        harness.adapter.probe.afterWrite = {
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
        harness.adapter.probe.afterWrite = {
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
        harness.adapter.probe.afterBackup = {
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
        harness.adapter.probe.afterBackup = {
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

    func testUnclosedAndDuplicateTOMLFailClosed() throws {
        let samples = [
            "model = [\n",
            "model = \"ok\"\nmodel = \"dup\"\n",
            "[server]\nkey = 1\n[server]\nkey = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }

    func testLegacyRawBackupFailsClosedWithoutOverwritingCurrentConfig() throws {
        let harness = try makeHarness(brokerHealth: "down")
        try harness.writeConfig("model = \"dirty\"\n", mode: 0o600)
        try FileManager.default.createDirectory(
            at: harness.backupDirectory,
            withIntermediateDirectories: true
        )
        let backup = harness.backupDirectory.appendingPathComponent("config.toml")
        try Data("model = \"original\"\n".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: backup.path
        )
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try harness.configText(), "model = \"dirty\"\n")
    }

    func testRedactedDiffHidesSingleQuotedBareAndOtherServerSecrets() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        TOKEN = '\(Harness.secret)'
        BARE = \(Harness.secret)
        [mcp_servers.github]
        command = "npx"
        args = ["--token", "\(Harness.secret)"]
        """, mode: 0o600)
        let preview = try harness.adapter.preview()
        XCTAssertFalse(preview.redactedDescription.contains(Harness.secret))
        XCTAssertTrue(preview.redactedDescription.contains("***"))
    }

    func testEmptyAssignmentAndDottedKeyConflictFailClosed() throws {
        let samples = [
            "model =\n",
            "[foo]\nbar = 1\n[foo.bar]\nx = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }

    func testLegalMultilineValueWithEqualsStillConnects() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        note = \"\"\"
        a = b
        \"\"\"
        """, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        XCTAssertTrue(try harness.configText().contains("a = b"))
        XCTAssertTrue(try harness.configText().contains("[mcp_servers.askkey]"))
    }

    func testDottedKeyParentCannotBeRedefinedAsExplicitTable() throws {
        let harness = try makeHarness()
        let original = "a.b = 1\n[a]\nc = 2\n"
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig)
        }
        XCTAssertEqual(try harness.configText(), original)
    }

    func testLegalMultilineArrayAndImplicitParentTableAreMerged() throws {
        let harness = try makeHarness()
        let original = """
        notify = [
          "/usr/bin/true",
        ]
        [a.b]
        x = 1
        [a]
        y = 2
        """
        try harness.writeConfig(original, mode: 0o600)

        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("notify = [\n  \"/usr/bin/true\",\n]"))
        XCTAssertTrue(after.contains("[a.b]\nx = 1\n[a]\ny = 2\n"))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
        XCTAssertTrue(try harness.adapter.hasConfiguration())
    }

    func testMultilineStringSecretsAreRedacted() throws {
        let harness = try makeHarness()
        try harness.writeConfig("""
        TOKEN = \"\"\"
        \(Harness.secret)
        \"\"\"
        OTHER = '''
        \(Harness.secret)
        '''
        """, mode: 0o600)
        let preview = try harness.adapter.preview()
        XCTAssertFalse(preview.redactedDescription.contains(Harness.secret))
        XCTAssertTrue(preview.redactedDescription.contains("***"))
    }

    func testEmptyKeyAndEmptyDottedSegmentsFailClosed() throws {
        let samples = [
            "= 1\n",
            ".foo = 1\n",
            "foo. = 1\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }

    func testArrayOfTablesAndQuotedKeyDoNotBlockAskKey() throws {
        let harness = try makeHarness()
        let original = """
        "a.b" = 1
        a.b = 2
        [[servers]]
        name = "one"
        [[servers]]
        name = "two"
        """
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("[[servers]]"))
        XCTAssertTrue(after.contains("name = \"one\""))
        XCTAssertTrue(after.contains("name = \"two\""))
        XCTAssertTrue(after.contains("\"a.b\" = 1"))
        XCTAssertTrue(after.contains("a.b = 2"))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
    }

    func testArrayTableMixedWithStandardTableOrValueFailsClosed() throws {
        let samples = [
            "[[a]]\nx = 1\n[a]\ny = 2\n",
            "[a]\ny = 2\n[[a]]\nx = 1\n",
            "a = 1\n[[a]]\nx = 2\n",
        ]
        for text in samples {
            let harness = try makeHarness()
            try harness.writeConfig(text, mode: 0o600)
            XCTAssertThrowsError(try harness.adapter.apply()) { error in
                XCTAssertEqual(error as? CodexUserMCPError, .illegalConfig, text)
            }
            XCTAssertEqual(try harness.configText(), text)
            XCTAssertFalse(try harness.configText().contains("[mcp_servers.askkey]"))
            XCTAssertNotEqual(harness.adapter.status(), .connected)
        }
    }

    func testNestedArrayOfTablesCanConnect() throws {
        let harness = try makeHarness()
        let original = """
        [[fruits]]
        name = "apple"
        [fruits.physical]
        color = "red"
        [[fruits]]
        name = "banana"
        [fruits.physical]
        color = "yellow"
        """
        try harness.writeConfig(original, mode: 0o600)
        XCTAssertEqual(try harness.adapter.apply().status, .connected)
        let after = try harness.configText()
        XCTAssertTrue(after.contains("name = \"apple\""))
        XCTAssertTrue(after.contains("name = \"banana\""))
        XCTAssertTrue(after.contains("color = \"red\""))
        XCTAssertTrue(after.contains("color = \"yellow\""))
        XCTAssertTrue(after.contains("[mcp_servers.askkey]"))
    }

    func testUnsupportedOfficialCLIVersionFailsClosed() throws {
        let harness = try makeHarness(cli: .supported("99.0.0", rewriteWithoutComments: false))
        try harness.writeConfig("model = \"keep\"\n", mode: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CodexUserMCPError, .unknownCodexVersion)
        }
        XCTAssertEqual(try harness.configText(), "model = \"keep\"\n")
        XCTAssertFalse(harness.cli.addCalled)
        XCTAssertFalse(harness.backupExists)
    }
}

private func makeIgnoringTerminationExecutable() throws -> URL {
    let directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
        .appendingPathComponent("akc-stubborn-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("stubborn-helper")
    try Data("""
    #!/bin/sh
    trap '' TERM
    exec /bin/sleep 4
    """.utf8).write(to: executable)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: executable.path
    )
    return executable
}

private struct CodexProcessFixture {
    let executable: URL

    init(harness: Harness, versionOutput: String = "codex-cli 0.154.0") throws {
        executable = harness.root.appendingPathComponent("codex-process-fixture")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let helperLiteral = String(decoding: try encoder.encode(harness.helperURL.path), as: UTF8.self)
        let entry = "[mcp_servers.askkey]\ncommand = \(helperLiteral)\nargs = [\"mcp\"]\n"
        // Fixtures always use a synthetic child; installed CLI acceptance is a separate opt-in test.
        // JSON fields: openai/codex rust-v0.154.0, codex-rs/cli/src/mcp_cmd.rs run_get.
        let server: [String: Any] = [
            "name": "askkey", "enabled": true,
            "transport": ["type": "stdio", "command": harness.helperURL.path, "args": ["mcp"]],
        ]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: server,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let script = """
        #!/bin/sh
        set -eu
        if [ "$#" -eq 1 ] && [ "$1" = '--version' ]; then
            printf '%s\\n' \(codexFixtureShellLiteral(versionOutput))
            exit 0
        fi
        if [ "$*" = 'mcp add --help' ]; then
            printf '%s\\n' 'Usage: codex mcp add [OPTIONS] <NAME> -- <COMMAND>...'
            exit 0
        fi
        case "${CODEX_HOME-}" in
            \(codexFixtureShellLiteral(harness.root.path))/*) ;;
            *) exit 73 ;;
        esac
        [ "${HOME-}" = "$(/usr/bin/dirname "$CODEX_HOME")" ] || exit 73
        if [ "$*" = 'mcp get askkey --json' ]; then
            /usr/bin/grep -q '^\\[mcp_servers\\.askkey\\]$' "$CODEX_HOME/config.toml"
            printf '%s\\n' \(codexFixtureShellLiteral(response))
            exit 0
        fi
        [ "$#" -eq 6 ] && [ "$1" = 'mcp' ] && [ "$2" = 'add' ] && [ "$3" = 'askkey' ] \\
            && [ "$4" = '--' ] && [ "$5" = \(codexFixtureShellLiteral(harness.helperURL.path)) ] \\
            && [ "$6" = 'mcp' ] || exit 64
        /bin/mkdir -p "$CODEX_HOME"
        printf '\\n%s\\n' \(codexFixtureShellLiteral(entry)) >> "$CODEX_HOME/config.toml"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}

private func codexFixtureShellLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func scopedCodexOutput(_ executable: URL, arguments: [String], config: URL) throws -> Data {
    let directory = config.deletingLastPathComponent()
    let result = try RestrictedProcess.run(.init(
        executable: executable,
        arguments: arguments,
        // Child-only settings: no process-global or shell HOME/CODEX_HOME mutation, no inherited auth tokens.
        environment: ["PATH": "/usr/bin:/bin", "HOME": directory.deletingLastPathComponent().path,
                      "CODEX_HOME": directory.path],
        currentDirectory: directory.deletingLastPathComponent(),
        timeout: 5,
        usesMonotonicClock: true,
        maximumOutputBytes: 65_536,
        truncateOutput: false
    ))
    guard !result.timedOut, result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    return result.stdout
}

private final class Harness {
    static let secret = "ghp_live_token_do_not_log"

    let root: URL
    let home: URL
    let project: URL
    let configURL: URL
    let projectConfigURL: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let cli: FakeCodexCLI
    let adapter: CodexUserMCPAdapter
    private let server: BrokerSocketServer?
    private let realHomeCodex: URL
    private let homeCodexStamp: Stamp?

    var wroteHomeCodex: Bool {
        Stamp(url: realHomeCodex) != homeCodexStamp
    }

    var wroteProjectConfig: Bool {
        (try? String(contentsOf: projectConfigURL, encoding: .utf8))?.contains("askkey") == true
    }

    var backupExists: Bool {
        FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent("config.toml").path)
    }

    var backupFileCount: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: backupDirectory.path).count) ?? 0
    }

    init(
        cli: FakeCodexCLI.Kind = .missing,
        brokerHealth: String = "ok",
        trustHelper: Bool = true,
        helperOverride: URL? = nil
    ) throws {
        let suffix = UUID().uuidString.prefix(8)
        root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("akc-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        configURL = CodexUserMCP.userConfigURL(home: home)
        projectConfigURL = project.appendingPathComponent(".codex/config.toml")
        backupDirectory = CodexUserMCP.managedBackupDirectory(
            applicationSupport: root.appendingPathComponent("AskKey", isDirectory: true)
        )
        socketPath = root.appendingPathComponent("broker.sock").path
        if let helperOverride {
            self.helperURL = helperOverride
        } else {
            self.helperURL = try Self.locateHelper()
        }
        realHomeCodex = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
        homeCodexStamp = Stamp(url: realHomeCodex)

        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fake = FakeCodexCLI(kind: cli, helperURL: helperURL, configURL: configURL)
        self.cli = fake

        if brokerHealth == "ok" {
            let server = BrokerSocketServer(
                socketPath: socketPath,
                handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
            )
            try server.start()
            self.server = server
        } else {
            self.server = nil
        }

        adapter = CodexUserMCPAdapter(
            configURL: configURL,
            helperURL: helperURL,
            backupDirectory: backupDirectory,
            brokerSocketPath: socketPath,
            command: fake.command,
            signing: CodexHelperSigning { _ in trustHelper }
        )
    }

    func close() {
        // Probes can retain their fixture. Break those cycles before cleanup.
        adapter.probe = CodexApplyProbe()
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    deinit { close() }

    func stopBroker() {
        server?.stop()
    }

    func makeAdapter(command: CodexMCPCommand) -> CodexUserMCPAdapter {
        CodexUserMCPAdapter(
            configURL: configURL, helperURL: helperURL, backupDirectory: backupDirectory,
            brokerSocketPath: socketPath, command: command, signing: .development
        )
    }

    func writeConfig(_ text: String, mode: Int) throws {
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: configURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: configURL.path
        )
    }

    func writeProjectConfig(_ text: String) throws {
        try Data(text.utf8).write(to: projectConfigURL)
    }

    func configText() throws -> String {
        try String(contentsOf: configURL, encoding: .utf8)
    }

    func projectConfigText() throws -> String {
        try String(contentsOf: projectConfigURL, encoding: .utf8)
    }

    func configMode() throws -> Int {
        try Self.mode(configURL)
    }

    func backupMode() throws -> Int {
        try Self.mode(backupDirectory.appendingPathComponent("config.toml"))
    }

    func backupDirectoryMode() throws -> Int {
        try Self.mode(backupDirectory)
    }

    func backupText() throws -> String {
        let url = backupDirectory.appendingPathComponent("config.toml")
        let data = try Data(contentsOf: url)
        if let backup = try? JSONDecoder().decode(CodexRollbackBackup.self, from: data) {
            return backup.originalText
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mode(_ url: URL) throws -> Int {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return Int(st.st_mode & 0o777)
    }

    private static func locateHelper() throws -> URL {
        let url = Bundle(for: CodexUserMCPAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

private struct Stamp: Equatable {
    var exists: Bool
    var size: Int?
    var mtime: Int64?

    init?(url: URL) {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            exists = false
            size = nil
            mtime = nil
            return
        }
        exists = true
        size = Int(st.st_size)
        mtime = Int64(st.st_mtimespec.tv_sec)
    }
}

final class FakeCodexCLI: @unchecked Sendable {
    enum Kind {
        case missing
        case supported(String, rewriteWithoutComments: Bool)
        case unknown(String?)
    }

    private let kind: Kind
    private let helperURL: URL
    private let configURL: URL
    private(set) var addCalled = false

    init(kind: Kind, helperURL: URL, configURL: URL) {
        self.kind = kind
        self.helperURL = helperURL
        self.configURL = configURL
    }

    var command: CodexMCPCommand {
        CodexMCPCommand(
            status: { [kind] in
                switch kind {
                case .missing: return .missing
                case .supported(let version, _): return .supported(version: version)
                case .unknown(let version): return .unknown(version: version)
                }
            },
            addAskKey: { [weak self] helper, config in
                guard let self else { return }
                self.addCalled = true
                guard case .supported(_, let rewrite) = self.kind, rewrite else { return }
                let body = """
                [mcp_servers.askkey]
                command = "\(helper.path)"
                args = ["mcp"]
                """
                try FileManager.default.createDirectory(
                    at: config.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(body.utf8).write(to: config)
            }
        )
    }
}
