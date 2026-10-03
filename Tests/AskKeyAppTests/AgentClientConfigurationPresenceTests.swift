import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConfigurationPresenceTests: AgentClientConnectorTestSupport {
    func testCodexConfigurationPresenceSurvivesUnavailableCLIAndRecognizesQuotedInlineForms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCodexPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config.toml")
        let adapter = codexAdapter(root: root, config: config, status: .unknown(version: "future"))
        XCTAssertFalse(try adapter.hasConfiguration())
        for source in [
            "[mcp_servers.askkey]\ncommand = \"/missing/helper\"\nargs = [\"mcp\"]\n",
            "[\"mcp_servers\".'askkey']\ncommand = \"/missing/helper\"\n",
            "[mcp_servers]\n\"askkey\" = { command = \"/missing/helper\", args = [\"mcp\"] }\n",
            "[mcp_servers]\n'askkey' = { command = \"/missing/helper\" }\n",
            "mcp_servers = { askkey = { command = \"/missing/helper\", args = [\"mcp\"] } }\n",
            "\"mcp_servers\" = { other = { args = [\"one,two\"], env = { X = \"a,b\" } }, 'askkey' = { command = \"/missing/helper\" } }\n",
        ] {
            let bytes = Data(source.utf8)
            try bytes.write(to: config)
            let preview = try AgentClientConnector.previewCodex(adapter)
            XCTAssertTrue(preview.configurationPresent)
            XCTAssertFalse(preview.connected)
            XCTAssertEqual(try Data(contentsOf: config), bytes)
        }
        for source in [
            "mcp_servers = { other = { askkey = { command = \"/missing/helper\" } } }\n",
            "mcp_servers = { other = { command = \"x, askkey = y\", args = [\"mcp\"] } }\n",
            "mcp_servers = { \"askkey.other\" = { command = \"/missing/helper\" } }\n",
        ] {
            try Data(source.utf8).write(to: config)
            XCTAssertFalse(try adapter.hasConfiguration())
        }
        try Data("mcp_servers = { askkey = { command = \"unterminated\n".utf8).write(to: config)
        XCTAssertThrowsError(try adapter.hasConfiguration())
        try Data("[mcp_servers.askkey\n".utf8).write(to: config)
        XCTAssertThrowsError(try AgentClientConnector.previewCodex(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }

    func testCursorConfigurationPresenceSurvivesMissingHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCursorPresence-\(UUID().uuidString)")
        let config = root.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: root,
            backupDirectory: root.appendingPathComponent("backup"),
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )
        XCTAssertFalse(try AgentClientConnector.previewCursor(adapter).configurationPresent)
        let bytes = Data(#"{"mcpServers":{"askkey":{"command":"/missing/helper","args":["mcp"]}}}"#.utf8)
        try bytes.write(to: config)
        let preview = try AgentClientConnector.previewCursor(adapter)
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertEqual(try Data(contentsOf: config), bytes)
        try Data("{".utf8).write(to: config)
        XCTAssertThrowsError(try AgentClientConnector.previewCursor(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }

    func testGrokConfigurationPresenceSurvivesMissingCLIAndHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyGrokPresence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = GrokCLIAdapter(
            grokHome: root,
            isolatedHome: root.appendingPathComponent("isolated"),
            helperExecutable: root.appendingPathComponent("missing-helper"),
            grokExecutable: root.appendingPathComponent("missing-grok"),
            backupDirectory: root.appendingPathComponent("backup"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )
        XCTAssertFalse(try adapter.hasConfiguration())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("isolated").path))
        XCTAssertFalse(try AgentClientConnector.previewGrok(adapter).configurationPresent)
        let bytes = Data("[mcp_servers.askkey]\ncommand = \"/missing/helper\"\nargs = [\"mcp\"]\n".utf8)
        try bytes.write(to: adapter.configURL)
        let preview = try AgentClientConnector.previewGrok(adapter)
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertEqual(try Data(contentsOf: adapter.configURL), bytes)
        try Data("[mcp_servers.askkey\n".utf8).write(to: adapter.configURL)
        XCTAssertThrowsError(try AgentClientConnector.previewGrok(adapter))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backup").path))
    }
}
