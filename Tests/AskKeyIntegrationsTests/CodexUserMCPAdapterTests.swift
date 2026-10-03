import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

class CodexUserMCPAdapterTests: AskKeyCoreTestCase {
    private var harnesses: [Harness] = []

    override func tearDown() {
        for harness in harnesses { harness.close() }
        harnesses.removeAll()
        super.tearDown()
    }

    func makeHarness(
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

    func assertCodexProcessVersionAllowsPreviewAndApply(_ version: String) throws {
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

    func assertCodexMCPAddGetJSONContract(executable: URL, expectedVersion: String,
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
}

func makeIgnoringTerminationExecutable() throws -> URL {
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
