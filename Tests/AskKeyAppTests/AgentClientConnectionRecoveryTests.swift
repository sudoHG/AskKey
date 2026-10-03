import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConnectionRecoveryTests: AgentClientConnectorTestSupport {
    func testCursorVerificationFailureRestoresOriginalConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorConnectorTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let config = home.appendingPathComponent(".cursor/mcp.json")
        let backup = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"mcpServers":{"existing":{"command":"/usr/bin/true"}}}"#.utf8)
        try original.write(to: config)
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )

        XCTAssertFalse(try AgentClientConnector.connectCursor(adapter))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }

    func testCursorRollbackFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorRollbackTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true),
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path,
            removeConfig: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let connected = await viewModel.loadAgentClientConnection {
            try AgentClientConnector.connectCursor(adapter)
        }

        XCTAssertNil(connected)
        XCTAssertEqual(viewModel.errorMessage, CursorMCPError.rollbackFailed.localizedDescription)
    }

    func testCursorBackupCleanupFailurePropagatesThroughConnectorAndUIState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = Bundle(for: AgentClientConnectorTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        let socket = "/tmp/akcc-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).sock"
        let server = BrokerSocketServer(
            socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: root.appendingPathComponent("backups", isDirectory: true),
            helperURL: helper,
            brokerSocketPath: socket,
            signing: .development,
            removeBackupItem: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })

        let connected = await viewModel.loadAgentClientConnection {
            try AgentClientConnector.connectCursor(adapter)
        }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            CursorMCPError.backupCleanupFailed.localizedDescription
        )
    }

    func testCursorPreviewDoesNotCreateLocksOrMutateBackups() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCursorPreviewTests-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backup = root.appendingPathComponent("client-backups/cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backup,
            helperURL: root.appendingPathComponent("missing-helper"),
            brokerSocketPath: root.appendingPathComponent("missing.sock").path
        )

        _ = try AgentClientConnector.previewCursor(adapter)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: backup.deletingLastPathComponent().appendingPathComponent(".cursor.lock").path
        ))
    }
}
