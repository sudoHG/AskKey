import Foundation
import XCTest
@testable import AskKeyApp

final class MulticaConnectionFailureTests: XCTestCase {
    func testConfigurationFlowRejectsEveryIssueCommand() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaConfiguration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("multica")
        let log = root.appendingPathComponent("calls")
        let serverCreated = root.appendingPathComponent("server-created")
        let assignmentCreated = root.appendingPathComponent("assignment-created")
        try Data("""
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2 $3" = "workspace mcp list" ]; then
          if [ -f "\(serverCreated.path)" ]; then
            echo '[{"id":"server-1","name":"askkey","transport":"stdio"}]'
          else
            echo '[]'
          fi
        elif [ "$1 $2 $3" = "workspace mcp add" ]; then
          cat >/dev/null
          touch "\(serverCreated.path)"
          echo '[{"id":"server-1","name":"askkey","transport":"stdio"}]'
        elif [ "$1 $2" = "agent list" ]; then
          echo '[{"id":"agent-1","name":"configured agent","archived_at":null}]'
        elif [ "$1 $2 $3" = "agent mcp list" ]; then
          if [ -f "\(assignmentCreated.path)" ]; then
            echo '[{"id":"server-1","name":"askkey","transport":"stdio","enabled":true}]'
          else
            echo '[]'
          fi
        elif [ "$1 $2 $3" = "agent mcp add" ]; then
          touch "\(assignmentCreated.path)"
          echo '{}'
        elif [ "$1" = "issue" ]; then
          echo 'issue commands are forbidden' >&2
          exit 97
        else
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/signed/askkey"),
            helperIsTrusted: { _ in true },
            command: command
        )

        XCTAssertTrue(try adapter.connect())
        let calls = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(calls.contains("workspace mcp add askkey workspace-1 --server-config-stdin --output json"))
        XCTAssertTrue(calls.contains("agent mcp add agent-1 server-1"))
        XCTAssertFalse(calls.contains("issue"))
    }

    func testExistingConfigurationIsReadableWithoutTrustedHelperOrMutations() throws {
        let probe = ExistingMulticaConfigurationProbe()
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/untrusted/askkey"),
            helperIsTrusted: { _ in false },
            command: probe.command
        )

        let preview = try adapter.preview()
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertTrue(try adapter.connect())
        XCTAssertEqual(probe.mutationCount, 0)
    }
}

private final class ExistingMulticaConfigurationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var mutationCount = 0

    var command: MulticaWorkspaceMCPCommand {
        MulticaWorkspaceMCPCommand(
            list: { [.init(id: "existing", name: "askkey", transport: "stdio")] },
            add: { _, _ in self.recordMutation(); throw MulticaConnectionError.invalidResponse },
            update: { _, _ in self.recordMutation(); throw MulticaConnectionError.invalidResponse },
            remove: { _ in self.recordMutation() },
            assignToAllAgents: { _ in self.recordMutation(); return [] },
            removeFromAgents: { _, _ in self.recordMutation() },
            currentWorkspace: {
                MulticaWorkspaceInfo(id: "workspace-1", name: "Default")
            },
            readAssignmentScope: {
                self.recordMutation()
                return MulticaAssignmentScope(
                    workspace: MulticaWorkspaceInfo(id: "workspace-1", name: "Default"),
                    agents: []
                )
            },
            assignToAgents: { _, _ in self.recordMutation(); return [] }
        )
    }

    private func recordMutation() {
        lock.withLock { mutationCount += 1 }
    }
}
