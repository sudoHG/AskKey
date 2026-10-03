import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

final class CodexCLIContractTests: CodexUserMCPAdapterTests {
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
                                           expectedVersion: version, harness: makeHarness())
    }
    func testBundledHelperPathUsesCanonicalAppHelperLocation() {
        XCTAssertEqual(
            CodexUserMCP.bundledHelperPath,
            "/Applications/Ask Key.app/Contents/Helpers/askkey"
        )
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
