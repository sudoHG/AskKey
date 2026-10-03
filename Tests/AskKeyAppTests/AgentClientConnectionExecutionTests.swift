import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConnectionExecutionTests: AgentClientConnectorTestSupport {
    func testGrokCleanupFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyGrokConnectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let grok = root.appendingPathComponent("grok")
        try Data("""
        #!/bin/sh
        if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
          echo "--scope user"
          exit 0
        fi
        echo "[]"
        exit 0
        """.utf8).write(to: grok)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: grok.path)
        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: false)
        let isolatedHome = root.appendingPathComponent("isolated", isDirectory: true)
        try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: false)
        let adapter = GrokCLIAdapter(
            grokHome: grokHome,
            isolatedHome: isolatedHome,
            helperExecutable: root.appendingPathComponent("helper"),
            grokExecutable: grok,
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            makeDiagnosticsProbe: {
                root.appendingPathComponent("diagnostics-probe", isDirectory: true)
            },
            removeDiagnosticsProbe: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewGrok(adapter)
        }
        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not = [[\n".utf8).write(to: config)
        let adapter = CodexUserMCPAdapter(
            configURL: config,
            helperURL: root.appendingPathComponent("helper"),
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            command: CodexMCPCommand(
                status: { .supported(version: "0.50.0") },
                addAskKey: { _, _ in }
            )
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexUnsafeConfigPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexUnsafePreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: root.appendingPathComponent("target"))
        let adapter = codexAdapter(root: root, config: config, status: .supported(version: "0.50.0"))
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCodexUnknownVersionPreviewFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCodexVersionPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: config)
        let adapter = codexAdapter(root: root, config: config, status: .unknown(version: "future"))
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let preview = await viewModel.loadAgentClientPreview {
            try AgentClientConnector.previewCodex(adapter)
        }

        XCTAssertNil(preview)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testAllCredentialSectionsExposeImportWithTheCorrectDestinationGroup() {
        XCTAssertEqual(CredentialWorkspaceSection.all.importDestinationGroup, nil)
        XCTAssertEqual(CredentialWorkspaceSection.ungrouped.importDestinationGroup, nil)
        XCTAssertEqual(CredentialWorkspaceSection.named("Work").importDestinationGroup, "Work")
        XCTAssertTrue(CredentialWorkspaceSection.all.showsCredentialImport)
        XCTAssertTrue(CredentialWorkspaceSection.ungrouped.showsCredentialImport)
        XCTAssertTrue(CredentialWorkspaceSection.named("Work").showsCredentialImport)
        XCTAssertFalse(CredentialWorkspaceSection.accessRecords.showsCredentialImport)
    }

    func testConnectionGateRejectsDuplicateAndStaleCompletions() throws {
        var gate = AgentConnectionGate()
        let first = try XCTUnwrap(gate.begin(.grok))
        XCTAssertNil(gate.begin(.grok))
        XCTAssertTrue(gate.isConnecting(.grok))
        XCTAssertTrue(gate.complete(.grok, generation: first))
        XCTAssertFalse(gate.complete(.grok, generation: first))
        let second = try XCTUnwrap(gate.begin(.grok))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.complete(.grok, generation: first))
        XCTAssertTrue(gate.complete(.grok, generation: second))
    }

    func testConnectorSerializesConcurrentConnectionsForTheSameClient() {
        let probe = ConnectionConcurrencyProbe()
        let group = DispatchGroup()
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                AgentClientConnector.performExclusive(client: .grok) {
                    probe.enter()
                    Thread.sleep(forTimeInterval: 0.05)
                    probe.leave()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.maximum, 1)
    }

    func testFailedConcurrentCursorConnectionDoesNotUndoSuccessfulConnection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorConcurrentTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backup = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Bundle(for: AgentClientConnectorTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("askkey")
        let socket = "/tmp/akcon-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        let successful = UnsafeSendableBox(CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: helper,
            brokerSocketPath: socket,
            signing: .development
        ))
        let failing = UnsafeSendableBox(CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: socket
        ))
        let group = DispatchGroup()
        let results = ConnectionResults()
        group.enter()
        DispatchQueue.global().async {
            results.append(try? AgentClientConnector.connectCursorExclusively(successful.value))
            group.leave()
        }
        Thread.sleep(forTimeInterval: 0.02)
        group.enter()
        DispatchQueue.global().async {
            results.append(try? AgentClientConnector.connectCursorExclusively(failing.value))
            group.leave()
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(results.values, [true, false])
        let config = home.appendingPathComponent(".cursor/mcp.json")
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("askkey"))
    }
}
