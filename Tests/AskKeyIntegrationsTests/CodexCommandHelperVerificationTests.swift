import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyIntegrations

final class CodexCommandHelperVerificationTests: XCTestCase {
    func testOldHelperWithoutCodexCommandCapabilityIsRejected() throws {
        for response in [
            #"{"protocolVersion":1,"clients":["cursor","grok","claude"]}"#,
            #"{"protocolVersion":2,"clients":["codex"]}"#,
            "{}", "invalid"
        ] {
            let fixture = try Fixture(response: response)
            XCTAssertThrowsError(try fixture.adapter.verifyCommandDiscoveryHelper())
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.adapter.configURL.path))
        }
    }

    func testCapabilityProbeRequiresTrustedHelperAndNeverCallsMCPOrBroker() throws {
        let fixture = try Fixture(response: #"{"protocolVersion":1,"clients":["codex"]}"#)
        XCTAssertNoThrow(try fixture.adapter.verifyCommandDiscoveryHelper())
        XCTAssertEqual(try String(contentsOf: fixture.arguments, encoding: .utf8), "hook\ncapabilities\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.adapter.configURL.path))
        let untrusted = try Fixture(response: #"{"protocolVersion":1,"clients":["codex"]}"#, trusted: false)
        XCTAssertThrowsError(try untrusted.adapter.verifyCommandDiscoveryHelper())
        XCTAssertFalse(FileManager.default.fileExists(atPath: untrusted.arguments.path))
    }

    func testDiscoveryVerificationAcceptsMCPWithoutTheLegacyGuardTool() throws {
        let fixture = try Fixture(response: #"{"protocolVersion":1,"clients":["codex"]}"#)
        let broker = BrokerSocketServer(socketPath: fixture.adapter.brokerSocketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil }))
        try broker.start()
        defer { broker.stop() }
        XCTAssertNoThrow(try fixture.adapter.verifyConnection(), "Command discovery does not require the legacy MCP guard")
    }

    private final class Fixture {
        let root: URL
        let arguments: URL
        let adapter: CodexUserMCPAdapter
        init(response: String, trusted: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ak-cap-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            arguments = root.appendingPathComponent("arguments.txt")
            let helper = root.appendingPathComponent("helper")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(arguments.path.replacingOccurrences(of: "'", with: "'\\''"))'
            if [ "$1" = "mcp" ]; then
                cat >/dev/null
                cat <<'MCP'
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"\(AskKeyVersion.current)"}}}
            {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
            MCP
                exit 0
            fi
            printf '%s\\n' '\(response.replacingOccurrences(of: "'", with: "'\\''"))'
            """
            try Data(script.utf8).write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            adapter = CodexUserMCPAdapter(configURL: root.appendingPathComponent("config.toml"),
                helperURL: helper, backupDirectory: root.appendingPathComponent("backups"),
                brokerSocketPath: root.appendingPathComponent("nonexistent.sock").path,
                signing: CodexHelperSigning { _ in trusted }, requiresCredentialDiscovery: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
