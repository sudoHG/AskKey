import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyCore

/// 331-393 public Grok status counterexample: a helper that omits jsonrpc,
/// protocolVersion, and serverInfo.name must not count as connected.
final class ReviewMCPHelperContractTests: XCTestCase {
    func testGrokStatusRejectsInitializeMissingJSONRPCProtocolAndServerName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyIndependentMCP-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let grokHome = root.appendingPathComponent("grok", isDirectory: true)
        let isolatedHome = root.appendingPathComponent("isolated", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)

        let health = String(
            decoding: try JSONEncoder().encode(
                BrokerResponse.success(.health(.init(
                    version: BrokerProtocolVersion.current,
                    status: "ok"
                )))
            ),
            as: UTF8.self
        )
        let helper = try executable(
            at: root.appendingPathComponent("malformed-helper"),
            source: """
            #!/bin/sh
            if [ "$1" = "mcp" ]; then
              echo '{"id":1,"result":{"serverInfo":{"version":"0.1.0"}}}'
              echo '{"id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}'
              exit 0
            fi
            if [ "$1" = "health" ]; then
              echo '\(health)'
              exit 0
            fi
            exit 1
            """
        )
        let grok = try executable(
            at: root.appendingPathComponent("grok-cli"),
            source: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(helper.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}]}'
              exit 0
            fi
            exit 1
            """
        )
        try Data("""
        [mcp_servers.askkey]
        command = "\(helper.path)"
        args = ["mcp"]
        enabled = true
        """.utf8).write(to: grokHome.appendingPathComponent("config.toml"))

        let adapter = GrokCLIAdapter(
            grokHome: grokHome,
            isolatedHome: isolatedHome,
            helperExecutable: helper,
            grokExecutable: grok,
            backupDirectory: backup,
            brokerSocketPath: root.appendingPathComponent("unused.sock").path,
            signing: .development
        )

        let result = try adapter.status()
        XCTAssertFalse(
            result.connected,
            "Grok accepted an initialize result with no jsonrpc version, protocolVersion, or server name"
        )
    }

    func testSharedContractRejectsMalformedAndWrongIdentityButKeepsLegalResponses() throws {
        let legalInitialize = """
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"0.1.0"}}}
        """
        let legalTools = """
        {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
        """
        let legal = try MCPHelperContract.inspect(
            legalInitialize + "\n" + legalTools,
            identity: .askKeyHelper
        )
        XCTAssertEqual(legal.version, "0.1.0")
        XCTAssertEqual(Set(legal.tools), ["list_credentials", "run"])

        let grokLegal = try MCPHelperContract.inspect(
            legalInitialize + "\n" + legalTools,
            identity: .grokClient
        )
        XCTAssertEqual(grokLegal.version, "0.1.0")

        let cursorLegal = try MCPHelperContract.inspect(
            legalInitialize + "\n" + legalTools,
            identity: .cursorClient
        )
        XCTAssertEqual(cursorLegal.version, "0.1.0")

        XCTAssertThrowsError(
            try MCPHelperContract.inspect(
                """
                {"id":1,"result":{"serverInfo":{"version":"0.1.0"}}}
                {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
                """,
                identity: .askKeyHelper
            )
        ) { error in
            XCTAssertEqual(error as? MCPHelperContract.Failure, .malformed)
        }

        XCTAssertThrowsError(
            try MCPHelperContract.inspect(
                """
                {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"other","version":"0.1.0"}}}
                {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
                """,
                identity: .askKeyHelper
            )
        ) { error in
            XCTAssertEqual(error as? MCPHelperContract.Failure, .unexpectedIdentity)
        }

        XCTAssertThrowsError(
            try MCPHelperContract.inspect(
                """
                {"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"boom"}}
                {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}
                """,
                identity: .askKeyHelper
            )
        ) { error in
            XCTAssertEqual(error as? MCPHelperContract.Failure, .malformed)
        }

        let payload = try MCPHelperContract.requestPayload(.cursorClient)
        let lines = String(decoding: payload, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines.count, 2)
        let initialize = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        let tools = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
        )
        XCTAssertEqual(initialize["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(initialize["method"] as? String, "initialize")
        let params = try XCTUnwrap(initialize["params"] as? [String: Any])
        XCTAssertEqual(params["protocolVersion"] as? String, "2024-11-05")
        let client = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(client["name"] as? String, "cursor")
        XCTAssertEqual(tools["method"] as? String, "tools/list")
        XCTAssertEqual(tools["jsonrpc"] as? String, "2.0")
    }

    private func executable(at url: URL, source: String) throws -> URL {
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
