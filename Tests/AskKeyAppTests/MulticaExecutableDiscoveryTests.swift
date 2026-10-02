import Foundation
import XCTest
@testable import AskKeyApp

final class MulticaExecutableDiscoveryTests: XCTestCase {
    func testOrdinaryPreviewFindsInstalledCLIWithoutChangingIsolatedConfiguration() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try installStub(in: fixture.installed, trace: fixture.trace)
        let connector = AgentClientConnector(home: fixture.config, installationHome: fixture.installed)
        _ = try ProcessMulticaWorkspaceMCPCommand.make(executable: connector.resolvedMulticaExecutable()).list()
        let calls = try String(contentsOf: fixture.trace, encoding: .utf8)
        XCTAssertTrue(calls.contains("workspace list"))
        XCTAssertTrue(calls.contains("workspace mcp list"))
        XCTAssertEqual(try Data(contentsOf: fixture.config.appendingPathComponent("sentinel")), Data("unchanged".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.config.path), ["sentinel"])
    }

    func testExplicitHomeStillSupportsIsolatedStub() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try installStub(in: fixture.config, trace: fixture.trace)
        _ = try ProcessMulticaWorkspaceMCPCommand.make(executable: AgentClientConnector(home: fixture.config).resolvedMulticaExecutable()).list()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.trace.path))
    }

    func testDedicatedE2ENeverFallsBackToInstalledCLI() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try installStub(in: fixture.installed, trace: fixture.trace)
        let connector = AgentClientConnector(
            home: fixture.config, installationHome: fixture.installed,
            multicaDebugServerName: "askkey-debug-isolated"
        )
        XCTAssertThrowsError(try ProcessMulticaWorkspaceMCPCommand.make(executable: connector.resolvedMulticaExecutable()).list()) { error in
            guard case MulticaConnectionError.cliNotInstalled = error else {
                return XCTFail("Expected missing isolated CLI, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.trace.path))
    }

    private func makeFixture() throws -> (root: URL, config: URL, installed: URL, trace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askkey-cli-discovery-\(UUID().uuidString)")
        let config = root.appendingPathComponent("config")
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try Data("unchanged".utf8).write(to: config.appendingPathComponent("sentinel"))
        return (root, config, installed, root.appendingPathComponent("calls"))
    }

    private func installStub(in home: URL, trace: URL) throws {
        let executable = home.appendingPathComponent(".local/bin/multica")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(trace.path)'
        case "$1 $2 $3" in
          'workspace list --output') printf '[{"id":"synthetic-workspace"}]' ;;
          'workspace mcp list') printf '[]' ;;
          *) exit 64 ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}
