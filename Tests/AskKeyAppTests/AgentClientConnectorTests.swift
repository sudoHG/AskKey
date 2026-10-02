import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
import AskKeyBroker
@testable import AskKeyCore

@MainActor
final class AgentClientConnectorTests: XCTestCase {
#if DEBUG
    func testDebugClientE2ERequestRequiresAnIsolatedHome() throws {
        let actualHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e2e-\(UUID().uuidString)", isDirectory: true)
        let isolatedHome = root.appendingPathComponent("home", isDirectory: true)
        try? FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: isolatedHome.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let output = isolatedHome.appendingPathComponent("result.json")
        let environment = [
            "ASKKEY_CLIENT_E2E": "codex",
            "ASKKEY_CLIENT_E2E_HOME": isolatedHome.path,
            "ASKKEY_CLIENT_E2E_OUTPUT": output.path,
        ]

        let request = DebugClientE2ERequest.parse(
            environment: environment,
            actualHome: actualHome
        )
        XCTAssertEqual(request?.client, .codex)
        XCTAssertEqual(request?.home, isolatedHome)
        XCTAssertEqual(request?.output, output)

        var multica = environment
        multica["ASKKEY_CLIENT_E2E"] = "multica"
        try makeExecutableMulticaStub(in: isolatedHome)
        multica["ASKKEY_MULTICA_E2E_SERVER_NAME"] = "askkey-debug-123"
        let multicaRequest = DebugClientE2ERequest.parse(environment: multica, actualHome: actualHome)
        XCTAssertEqual(
            multicaRequest?.client,
            .multica
        )
        XCTAssertEqual(multicaRequest?.multicaServerName, "askkey-debug-123")
        multica["ASKKEY_MULTICA_E2E_SERVER_NAME"] = "unsafe/name"
        XCTAssertNil(DebugClientE2ERequest.parse(environment: multica, actualHome: actualHome))

        var unsafe = environment
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = actualHome.path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
        try? FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: actualHome)
        unsafe["ASKKEY_CLIENT_E2E_HOME"] = linkedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = linkedHome.appendingPathComponent("result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))

        unsafe["ASKKEY_CLIENT_E2E_HOME"] = isolatedHome.path
        unsafe["ASKKEY_CLIENT_E2E_OUTPUT"] = isolatedHome
            .appendingPathComponent("missing/result.json").path
        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: unsafe,
            actualHome: actualHome
        ))
    }

    func testDebugMulticaRequestRejectsMissingTemporaryServerName() throws {
        let fixture = try makeDebugMulticaFixture(serverName: nil, includesStub: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: fixture.environment,
            actualHome: fixture.actualHome
        ))
    }

    func testDebugMulticaRequestRejectsProductionServerName() throws {
        let fixture = try makeDebugMulticaFixture(serverName: "askkey", includesStub: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: fixture.environment,
            actualHome: fixture.actualHome
        ))
    }

    func testDebugMulticaRequestRejectsMissingIsolatedStub() throws {
        let fixture = try makeDebugMulticaFixture(
            serverName: "askkey-debug-missing-stub",
            includesStub: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNil(DebugClientE2ERequest.parse(
            environment: fixture.environment,
            actualHome: fixture.actualHome
        ))
    }

    private func makeDebugMulticaFixture(
        serverName: String?,
        includesStub: Bool
    ) throws -> (root: URL, actualHome: URL, environment: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-multica-e2e-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        if includesStub { try makeExecutableMulticaStub(in: home) }
        var environment = [
            "ASKKEY_CLIENT_E2E": "multica",
            "ASKKEY_CLIENT_E2E_HOME": home.path,
            "ASKKEY_CLIENT_E2E_OUTPUT": home.appendingPathComponent("result.json").path,
        ]
        environment["ASKKEY_MULTICA_E2E_SERVER_NAME"] = serverName
        return (root, URL(fileURLWithPath: "/Users/example", isDirectory: true), environment)
    }

    private func makeExecutableMulticaStub(in home: URL) throws {
        let directory = home.appendingPathComponent(".local/bin", isDirectory: true)
        let stub = directory.appendingPathComponent("multica")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
    }

    func testDebugClientE2EFalseResultRecordsFailureAndRollback() {
        let result = DebugClientE2EResult.completed(client: .cursor, connected: false)

        XCTAssertFalse(result.connected)
        XCTAssertEqual(result.rollback, "completed")
        XCTAssertNotNil(result.error)
    }
#endif

    func testEverySupportedClientUsesAutomaticConnection() {
        XCTAssertTrue(AgentClient.allCases.allSatisfy(\.isAutomatic))
    }

    func testMulticaCreatesReadsBackAndAssignsConfiguration() throws {
        let probe = MulticaCommandProbe()
        let helperURL = URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey")
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: helperURL,
            helperIsTrusted: { $0 == helperURL },
            command: probe.command
        )

        XCTAssertTrue(try adapter.connect())
        XCTAssertEqual(probe.addedNames, ["askkey"])
        XCTAssertEqual(probe.assignedServerIDs, ["created-id"])
        XCTAssertTrue(probe.removedIDs.isEmpty)
    }

    func testMulticaConfigurationReadbackFailureRollsBackNewServer() {
        let probe = MulticaCommandProbe(
            serverAfterConfiguration: .init(id: "created-id", name: "askkey", transport: "http")
        )
        let helperURL = URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey")
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: helperURL,
            helperIsTrusted: { $0 == helperURL },
            command: probe.command
        )

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .verificationFailed)
        }
        XCTAssertEqual(probe.removedIDs, ["created-id"])
    }

    func testMulticaDebugServerIsRemovedAfterSuccessfulConfiguration() throws {
        let probe = MulticaCommandProbe()
        let helperURL = URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey")
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: helperURL,
            helperIsTrusted: { $0 == helperURL },
            command: probe.command,
            serverName: "askkey-debug-123",
            removeCreatedServerAfterConfiguration: true
        )

        XCTAssertTrue(try adapter.connect())
        XCTAssertEqual(probe.addedNames, ["askkey-debug-123"])
        XCTAssertEqual(probe.removedIDs, ["created-id"])
    }

    func testMulticaExistingConfigurationIsReadyWithoutMutatingIt() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "zh-Hans"
        let probe = MulticaCommandProbe(
            existing: [.init(id: "existing-id", name: "askkey", transport: "stdio")]
        )
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: CodexHelperSigning.development.isTrusted,
            command: probe.command
        )

        let preview = try adapter.preview()
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertTrue(preview.summary.contains("配置"))
        XCTAssertFalse(preview.summary.contains("检测"))
        XCTAssertFalse(preview.summary.contains("额度"))
        XCTAssertTrue(try adapter.connect())
        XCTAssertTrue(probe.addedNames.isEmpty)
        XCTAssertTrue(probe.removedIDs.isEmpty)
        XCTAssertTrue(probe.updatedServerIDs.isEmpty)
        XCTAssertTrue(probe.assignedServerIDs.isEmpty)
    }

    func testMulticaExistingConfigurationDoesNotRequireTrustedHelper() throws {
        let probe = MulticaCommandProbe(
            existing: [
                .init(id: "existing-id", name: "askkey", transport: "stdio"),
                .init(id: "duplicate-id", name: "askkey", transport: "http")
            ]
        )
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in false },
            command: probe.command
        )

        let preview = try adapter.preview()
        XCTAssertTrue(preview.configurationPresent)
        XCTAssertFalse(preview.connected)
        XCTAssertTrue(try adapter.connect())
        XCTAssertTrue(probe.addedNames.isEmpty)
        XCTAssertTrue(probe.removedIDs.isEmpty)
        XCTAssertTrue(probe.assignedServerIDs.isEmpty)
    }

    func testMulticaMissingConfigurationStillRequiresTrustedHelperBeforeWriting() {
        let probe = MulticaCommandProbe()
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in false },
            command: probe.command
        )

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .untrustedHelper)
        }
        XCTAssertTrue(probe.addedNames.isEmpty)
        XCTAssertTrue(probe.updatedServerIDs.isEmpty)
        XCTAssertTrue(probe.assignedServerIDs.isEmpty)
        XCTAssertTrue(probe.unassignedAgentIDs.isEmpty)
        XCTAssertTrue(probe.removedIDs.isEmpty)
    }

    func testMulticaRejectsAnUntrustedHelperBeforeReadingOrWritingTheWorkspace() {
        let probe = MulticaCommandProbe()
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in false },
            command: probe.command
        )

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .untrustedHelper)
        }
        XCTAssertTrue(probe.addedNames.isEmpty)
    }

    func testMulticaFailuresExplainOneActionWithoutInternalPayloads() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let errors: [MulticaConnectionError] = [
            .cliNotInstalled, .cliCouldNotStart, .communicationFailed, .timedOut,
            .commandFailed(.listWorkspaces), .notLoggedIn, .noWorkspace, .workspaceChoiceRequired,
            .permissionDenied, .unsupportedServer,
            .invalidResponse, .untrustedHelper, .verificationFailed, .rollbackFailed,
            .creationRecoveryRequired,
        ]
        for language in ["zh-Hans", "en"] {
            AppLanguage.current = language
            for error in errors {
                let message = error.localizedDescription
                XCTAssertFalse(message.contains("{"), message)
                XCTAssertFalse(message.contains("}"), message)
                XCTAssertFalse(message.lowercased().contains("error code"), message)
                XCTAssertFalse(message.contains("查看账号状态"), message)
                XCTAssertFalse(message.contains("account status"), message)
                XCTAssertTrue(
                    message.contains(language == "zh-Hans" ? "请" : "try again")
                        || message.contains(language == "zh-Hans" ? "再重试" : "then try again")
                        || message.contains(language == "zh-Hans" ? "请旨支持" : "Ask Key support")
                        || ["Inspect", "Check", "Update", "Reopen"].contains(where: message.contains),
                    message
                )
            }
        }
    }

    func testMulticaCLIOutputIsDrainedAndBoundedWithoutWaitingForTimeout() throws {
        let executable = try makeMulticaStub("""
        #!/bin/sh
        head -c 1100000 /dev/zero | tr '\\0' x
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)
        let started = Date()

        XCTAssertThrowsError(try command.list()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .invalidResponse)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testMulticaCLIMapsPermissionFailureWithoutShowingStderr() throws {
        let executable = try makeMulticaStub("""
        #!/bin/sh
        echo 'not authorized: internal code 401' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertThrowsError(try command.list()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .permissionDenied)
            XCTAssertFalse(error.localizedDescription.contains("401"))
        }
    }

    func testMulticaCLIReportsTheFailedStepWithoutEchoingUnknownStderr() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "zh-Hans"
        let executable = try makeMulticaStub("""
        #!/bin/sh
        echo 'remote policy blocks stdio servers' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertThrowsError(try command.list()) { error in
            XCTAssertEqual(
                error as? MulticaConnectionError,
                .commandFailed(.listWorkspaces)
            )
            XCTAssertTrue(error.localizedDescription.contains("读取工作区"))
            XCTAssertFalse(error.localizedDescription.contains("remote policy"))
            XCTAssertFalse(error.localizedDescription.contains("没有提供可安全显示的原因"))
        }
    }

    func testMulticaCLIExplainsMissingLocalSetup() throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "zh-Hans"
        let executable = try makeMulticaStub("""
        #!/bin/sh
        echo "No server configured. Run 'multica setup' first." >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertThrowsError(try command.list()) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .cliNotConfigured)
            XCTAssertTrue(error.localizedDescription.contains("multica setup"))
            XCTAssertFalse(error.localizedDescription.contains("没有提供可安全显示的原因"))
        }
    }

    func testMulticaChildUsesUserHomeAndDropsAgentExecutionContext() throws {
        let previousHome = ProcessInfo.processInfo.environment["HOME"]
        let previousToken = ProcessInfo.processInfo.environment["MULTICA_TOKEN"]
        let previousTask = ProcessInfo.processInfo.environment["MULTICA_TASK_ID"]
        setenv("HOME", "/definitely/not/the/user-home", 1)
        setenv("MULTICA_TOKEN", "mat_test_only", 1)
        setenv("MULTICA_TASK_ID", "task-test-only", 1)
        defer {
            if let previousHome { setenv("HOME", previousHome, 1) } else { unsetenv("HOME") }
            if let previousToken { setenv("MULTICA_TOKEN", previousToken, 1) } else { unsetenv("MULTICA_TOKEN") }
            if let previousTask { setenv("MULTICA_TASK_ID", previousTask, 1) } else { unsetenv("MULTICA_TASK_ID") }
        }
        let executable = try makeMulticaStub("""
        #!/bin/sh
        if [ "$PWD" != "$HOME" ] || env | grep -q '^MULTICA_\\(TOKEN\\|TASK_\\)'; then
          echo "No server configured. Run 'multica setup' first." >&2
          exit 1
        fi
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2 $3" = "workspace mcp list" ]; then
          echo '[]'
        else
          exit 1
        fi
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertTrue(try command.list().isEmpty)
    }

    func testMulticaProcessConfigurationFlowRejectsIssueCommands() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaFlow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let serverCreated = root.appendingPathComponent("server-created")
        let assignedAgent = root.appendingPathComponent("assigned-agent")
        let executable = root.appendingPathComponent("multica")
        try Data("""
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1","name":"331-Works","slug":"331-works"}]'
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
          echo '[{"id":"agent-1","name":"开发｜快修","archived_at":null}]'
        elif [ "$1 $2 $3" = "agent mcp add" ]; then
          touch "\(assignedAgent.path)"
          echo '{}'
        elif [ "$1 $2 $3" = "agent mcp list" ]; then
          if [ -f "\(assignedAgent.path)" ]; then
            echo '[{"id":"server-1","name":"askkey","transport":"stdio","enabled":true}]'
          else
            echo '[]'
          fi
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
        XCTAssertTrue(calls.contains("workspace list --output json"))
        XCTAssertEqual(calls.components(separatedBy: "workspace list --output json").count - 1, 1)
        XCTAssertTrue(calls.contains("agent list --output json --workspace-id workspace-1"))
        XCTAssertTrue(calls.contains("workspace mcp add askkey workspace-1 --server-config-stdin --output json"))
        XCTAssertTrue(calls.contains("agent mcp add agent-1 server-1"))
        XCTAssertTrue(calls.contains("agent mcp list agent-1"))
        XCTAssertFalse(calls.contains("issue"))
    }

    func testMulticaProcessAssignmentFailureRollsBackOnlyAgentsMissingTheServerInitially() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaAssignmentRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let assignedAgent2 = root.appendingPathComponent("assigned-agent-2")
        let executable = root.appendingPathComponent("multica")
        try Data("""
        #!/bin/sh
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2" = "agent list" ]; then
          echo '[{"id":"agent-1","name":"existing","archived_at":null},{"id":"agent-2","name":"new","archived_at":null},{"id":"agent-3","name":"fails","archived_at":null}]'
        elif [ "$1 $2 $3" = "agent mcp list" ]; then
          if [ "$4" = "agent-1" ] || { [ "$4" = "agent-2" ] && [ -f "\(assignedAgent2.path)" ]; }; then
            echo '[{"id":"server-1","name":"askkey","transport":"stdio"}]'
          else
            echo '[]'
          fi
        elif [ "$1 $2 $3 $4" = "agent mcp add agent-2" ]; then
          touch "\(assignedAgent2.path)"
          echo '{}'
        elif [ "$1 $2 $3 $4" = "agent mcp add agent-3" ]; then
          echo 'permission denied' >&2
          exit 1
        elif [ "$1 $2 $3 $4" = "agent mcp remove agent-2" ]; then
          rm "\(assignedAgent2.path)"
          echo '{}'
        else
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertThrowsError(try command.assignToAllAgents("server-1")) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .permissionDenied)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: assignedAgent2.path))
    }

    func testMulticaProcessUpdateReplacesTheExistingServerConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.json")
        let executable = root.appendingPathComponent("multica")
        try Data("""
        #!/bin/sh
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2 $3" = "workspace mcp update" ]; then
          cat > "\(input.path)"
          echo '{"id":"server-1","name":"askkey","transport":"stdio"}'
        elif [ "$1 $2 $3" = "workspace mcp list" ]; then
          echo '[{"id":"server-1","name":"askkey","transport":"stdio"}]'
        else
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertEqual(
            try command.update("server-1", .init(command: "/signed/askkey", args: ["mcp"])),
            .init(id: "server-1", name: "askkey", transport: "stdio")
        )
        let configuration = try JSONDecoder().decode(
            MulticaMCPConfiguration.self,
            from: Data(contentsOf: input)
        )
        XCTAssertEqual(configuration, .init(command: "/signed/askkey", args: ["mcp"]))
    }

    func testMulticaProcessAddResolvesTheOnlyWorkspaceAndAcceptsArrayResponse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaAdd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("calls.log")
        let executable = root.appendingPathComponent("multica")
        try Data("""
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2 $3" = "workspace mcp list" ]; then
          echo '[]'
        elif [ "$1 $2 $3" = "workspace mcp add" ]; then
          cat >/dev/null
          echo '[{"id":"server-1","name":"askkey","transport":"stdio"}]'
        else
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        let server = try command.add("askkey", .init(command: "/signed/askkey", args: ["mcp"]))

        XCTAssertEqual(server, .init(id: "server-1", name: "askkey", transport: "stdio"))
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains(
            "workspace mcp add askkey workspace-1 --server-config-stdin --output json"
        ))
    }

    func testMulticaProcessMalformedAddResponsePreservesUnattributableConcurrentServer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaInvalidAdd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("created")
        let log = root.appendingPathComponent("calls.log")
        let executable = root.appendingPathComponent("multica")
        try Data("""
        #!/bin/sh
        echo "$*" >> "\(log.path)"
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"}]'
        elif [ "$1 $2 $3" = "workspace mcp list" ]; then
          if [ -f "\(state.path)" ]; then
            echo '[{"id":"concurrent-user-server","name":"askkey","transport":"stdio"}]'
          else
            echo '[]'
          fi
        elif [ "$1 $2 $3" = "workspace mcp add" ]; then
          cat >/dev/null
          touch "\(state.path)"
          echo '{malformed-success}'
        elif [ "$1 $2 $3" = "workspace mcp remove" ]; then
          rm "\(state.path)"
          echo 'removed'
        else
          exit 1
        fi
        """.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertThrowsError(try command.add("askkey", .init(command: "/signed/askkey", args: ["mcp"]))) { error in
            XCTAssertEqual(error as? MulticaConnectionError, .creationRecoveryRequired)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains("workspace mcp remove"))
    }

    func testMulticaProcessFailedOrTimedOutAddPreservesConcurrentServerAndRequiresRecovery() throws {
        for failure in ["exit 7", "exec /bin/sleep 10"] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AskKeyMulticaUncertainAdd-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let state = root.appendingPathComponent("concurrent-user-server")
            let log = root.appendingPathComponent("calls.log")
            let executable = root.appendingPathComponent("multica")
            try Data("""
            #!/bin/sh
            echo "$*" >> "\(log.path)"
            if [ "$1 $2" = "workspace list" ]; then
              echo '[{"id":"workspace-1"}]'
            elif [ "$1 $2 $3" = "workspace mcp list" ]; then
              if [ -f "\(state.path)" ]; then
                echo '[{"id":"concurrent-user-server","name":"askkey","transport":"stdio"}]'
              else
                echo '[]'
              fi
            elif [ "$1 $2 $3" = "workspace mcp add" ]; then
              cat >/dev/null
              touch "\(state.path)"
              \(failure)
            elif [ "$1 $2 $3" = "workspace mcp remove" ]; then
              rm "\(state.path)"
            else
              exit 1
            fi
            """.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable, addTimeout: 0.1)
            XCTAssertThrowsError(try command.add("askkey", .init(command: "/signed/askkey", args: ["mcp"]))) {
                XCTAssertEqual($0 as? MulticaConnectionError, .creationRecoveryRequired)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))
            let calls = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(calls.components(separatedBy: "workspace mcp add").count - 1, 1)
            XCTAssertFalse(calls.contains("workspace mcp remove"))
            XCTAssertFalse(calls.contains("agent mcp add"))
            XCTAssertFalse(calls.contains("issue create"))
        }
    }

    func testMulticaProcessUsesDefaultWorkspaceWhenSeveralAreAvailable() throws {
        let executable = try makeMulticaStub("""
        #!/bin/sh
        if [ "$1 $2" = "workspace list" ]; then
          echo '[{"id":"workspace-1"},{"id":"workspace-2"}]'
        elif [ "$1 $2" = "workspace get" ]; then
          echo '{"id":"workspace-2"}'
        elif [ "$1 $2 $3 $4" = "workspace mcp list workspace-2" ]; then
          echo '[]'
        else
          exit 1
        fi
        """)
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable)

        XCTAssertTrue(try command.list().isEmpty)
    }

    func testAutomaticClientPreviewsExplainBackupWriteAndVerificationWithoutRawConfig() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "en"

        for client in [AgentClient.codex, .cursor, .grok] {
            let summary = client.connectionPreviewSummary

            XCTAssertTrue(summary.contains("back up"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("add Ask Key"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("verify"), "\(client.rawValue): \(summary)")
            XCTAssertFalse(summary.contains("--- before"))
            XCTAssertFalse(summary.contains("+++ after"))
            XCTAssertFalse(summary.contains("[skills.config]"))
            XCTAssertFalse(summary.contains("{"))
        }
    }

    func testActiveManagementSessionConnectsWithoutAnotherAuthentication() async {
        var authenticationRequests = 0
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            authenticateDeviceOwner: { _ in
                authenticationRequests += 1
                return .allow
            }
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient { true }

        XCTAssertEqual(connected, true)
        XCTAssertEqual(authenticationRequests, 0)
    }

    func testUnknownCodexVersionDoesNotTellNewerClientsToUpgrade() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["zh-Hans", "en"] {
            AppLanguage.current = language
            let message = AgentClientErrorCopy.message(for: .codex, error: CodexUserMCPError.unknownCodexVersion)
            XCTAssertFalse(message.contains("升级"))
            XCTAssertFalse(message.contains("Update Codex"))
            XCTAssertTrue(message.contains(language == "en" ? "compatibility" : "兼容性"))
        }
    }

    func testClientVerificationFailureUsesOneHumanNextStepWithoutInternalReason() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "AgentClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.grok) {
            throw GrokCLIAdapterError.verificationFailed("helper_signature_internal_401")
        }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "请旨助手的签名或版本不匹配。请重新安装请旨，再重试。"
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("401") == true)
    }

    func testFalseClientVerificationExplainsTheSingleRetryAction() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "FalseClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.cursor) { false }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Cursor 没有完成连接检测。请重启 Cursor，再重试。"
        )
    }

    func testLockedVaultDoesNotWriteClientConfigurationWithAStaleManagementFlag() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.isLocked = true
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
    }

    func testExpiredManagementSessionDoesNotWriteClientConfiguration() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.hasManagementSession = false

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            appLocalized("Credential management requires confirmation before it can continue.")
        )
    }

    func testLockedApprovalUsesOnlyGenericReminderUntilScreenUnlocks() {
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .locked, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unlocked, language: "en"),
            .detailedConfirmation
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unknown, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
    }

    func testApprovalDetailsAreLoadedOnlyAfterExplicitlyUnlockedScreenState() {
        var loads = 0
        let load = {
            loads += 1
            return 42
        }

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .locked, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("locked screen loaded request details")
        }
        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unknown, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("unknown screen loaded request details")
        }
        XCTAssertEqual(loads, 0)

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unlocked, load: load) {
        case .lockedReminder:
            XCTFail("unlocked screen did not load request")
        case .detailed(let request):
            XCTAssertEqual(request, 42)
        }
        XCTAssertEqual(loads, 1)
    }

    func testLockedReminderIsMarkedPostedOnlyAfterSuccessfulDelivery() {
        XCTAssertTrue(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .delivered)
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(
                for: .authorizationUnavailable
            )
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .deliveryFailed)
        )
    }

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

    func testBundleEditorNeverOffersTheLegacyGlobalEnvironmentVariable() {
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: false,
                payloadKind: .text
            )
        )
        XCTAssertFalse(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .bundle
            )
        )
        XCTAssertTrue(
            CredentialEditorPresentation.showsGlobalEnvironmentVariable(
                editingExisting: true,
                payloadKind: .text
            )
        )
    }

    func testBundleEditorRejectsTheWholePersistedBundleWhenAFileComponentIsInvalid() {
        let components = [
            ManagedCredentialComponent(name: "USERNAME", value: .text("agent")),
            ManagedCredentialComponent(name: "CERTIFICATE", value: .file(filename: "", bytes: Data("x".utf8)))
        ]

        XCTAssertThrowsError(try CredentialEditorComponentLoader.load(components))
    }

    func testBundleEditorRejectsHalfFilledOptionalComponents() {
        let complete = CredentialComponentDraft(name: "PRIMARY", text: "value")

        XCTAssertTrue(CredentialEditorComponentValidation.canSave([complete]))
        XCTAssertTrue(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertNil(CredentialEditorComponentValidation.inputs([
            complete,
            CredentialComponentDraft(name: "SECONDARY", isOptional: true),
        ]))
        XCTAssertFalse(CredentialEditorComponentValidation.canSave([
            complete,
            CredentialComponentDraft(text: "orphan-value", isOptional: true),
        ]))
    }

    func testAPITemplateCanSaveWithAnEmptyEndpoint() throws {
        var components = CredentialTemplate.api.components
        guard let keyIndex = components.firstIndex(where: { $0.name == "API_KEY" }) else {
            return XCTFail("API template must include API_KEY")
        }
        components[keyIndex].text = "secret-key"

        XCTAssertTrue(CredentialEditorComponentValidation.canSave(components))
        let inputs = try XCTUnwrap(CredentialEditorComponentValidation.inputs(components))
        XCTAssertEqual(inputs.map(\.name), ["API_KEY"])

        guard let endpointIndex = components.firstIndex(where: { $0.name == "API_ENDPOINT" }) else {
            return XCTFail("API template must include API_ENDPOINT")
        }
        components[endpointIndex].name = "CUSTOM_SECRET"
        XCTAssertFalse(CredentialEditorComponentValidation.canSave(components))
        XCTAssertNil(CredentialEditorComponentValidation.inputs(components))
    }

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

    private func codexAdapter(
        root: URL,
        config: URL,
        status: CodexMCPCLIStatus
    ) -> CodexUserMCPAdapter {
        CodexUserMCPAdapter(
            configURL: config,
            helperURL: root.appendingPathComponent("helper"),
            backupDirectory: root.appendingPathComponent("backup", isDirectory: true),
            brokerSocketPath: root.appendingPathComponent("broker.sock").path,
            command: CodexMCPCommand(status: { status }, addAskKey: { _, _ in })
        )
    }

    private func makeMulticaStub(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyMulticaCLI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("multica")
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private final class ConnectionAttemptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var count: Int { lock.withLock { storage } }
    func record() { lock.withLock { storage += 1 } }
}

private final class MulticaCommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [MulticaMCPServer]
    private let serverAfterConfiguration: MulticaMCPServer?
    private(set) var addedNames: [String] = []
    private(set) var updatedServerIDs: [String] = []
    private(set) var removedIDs: [String] = []
    private(set) var assignedServerIDs: [String] = []
    private(set) var unassignedAgentIDs: [String] = []
    private let newlyAssignedAgentIDs: [String]

    init(
        existing: [MulticaMCPServer] = [],
        newlyAssignedAgentIDs: [String] = [],
        serverAfterConfiguration: MulticaMCPServer? = nil
    ) {
        servers = existing
        self.newlyAssignedAgentIDs = newlyAssignedAgentIDs
        self.serverAfterConfiguration = serverAfterConfiguration
    }

    var command: MulticaWorkspaceMCPCommand {
        MulticaWorkspaceMCPCommand(
            list: {
                self.lock.withLock {
                    if let replacement = self.serverAfterConfiguration, !self.addedNames.isEmpty {
                        self.servers = [replacement]
                    }
                    return self.servers
                }
            },
            add: { name, configuration in
                XCTAssertEqual(configuration.command, "/Applications/Ask Key.app/Contents/Helpers/askkey")
                XCTAssertEqual(configuration.args, ["mcp"])
                return self.lock.withLock {
                    self.addedNames.append(name)
                    let server = MulticaMCPServer(id: "created-id", name: name, transport: "stdio")
                    self.servers.append(server)
                    return server
                }
            },
            update: { id, configuration in
                XCTAssertEqual(configuration.command, "/Applications/Ask Key.app/Contents/Helpers/askkey")
                XCTAssertEqual(configuration.args, ["mcp"])
                return self.lock.withLock {
                    self.updatedServerIDs.append(id)
                    return self.servers.first { $0.id == id }
                        ?? MulticaMCPServer(id: id, name: "missing", transport: "missing")
                }
            },
            remove: { id in
                self.lock.withLock {
                    self.removedIDs.append(id)
                    self.servers.removeAll { $0.id == id }
                }
            },
            assignToAllAgents: { id in
                self.lock.withLock { self.assignedServerIDs.append(id) }
                return self.newlyAssignedAgentIDs
            },
            removeFromAgents: { _, agentIDs in
                self.lock.withLock { self.unassignedAgentIDs.append(contentsOf: agentIDs) }
            },
            currentWorkspace: {
                MulticaWorkspaceInfo(id: "workspace-1", name: "Default")
            },
            readAssignmentScope: {
                MulticaAssignmentScope(
                    workspace: MulticaWorkspaceInfo(id: "workspace-1", name: "Default"),
                    agents: [MulticaAgentTarget(id: "agent-1", name: "configured agent")]
                )
            },
            assignToAgents: { id, agentIDs in
                self.lock.withLock { self.assignedServerIDs.append(id) }
                return self.newlyAssignedAgentIDs.isEmpty ? agentIDs : self.newlyAssignedAgentIDs
            }
        )
    }
}

private final class ConnectionConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var highest = 0
    var maximum: Int { lock.withLock { highest } }

    func enter() {
        lock.withLock {
            active += 1
            highest = max(highest, active)
        }
    }

    func leave() { lock.withLock { active -= 1 } }
}

private final class ConnectionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool] = []
    var values: [Bool] { lock.withLock { storage } }
    func append(_ value: Bool?) { if let value { lock.withLock { storage.append(value) } } }
}

private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension AgentClientConnectorTests {
    func testMulticaProcessStopsDescendantsAfterLeaderExits() throws {
        try assertMulticaDescendantsStop(continuousOutput: false)
    }

    func testMulticaProcessStopsDescendantsWhenOutputExceedsLimit() throws {
        try assertMulticaDescendantsStop(continuousOutput: true)
    }

    func testMulticaProcessStopsDescendantsOnTimeout() throws {
        try assertMulticaDescendantsStop(continuousOutput: false, timeoutOnAdd: true)
    }

    private func assertMulticaDescendantsStop(continuousOutput: Bool, timeoutOnAdd: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyMulticaProcess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("multica")
        let pids = root.appendingPathComponent("children")
        let heartbeat = root.appendingPathComponent("heartbeat")
        let script = """
        #!/usr/bin/python3 -I
        import os, signal, sys, time
        child = os.fork()
        if child == 0:
            signal.alarm(5)
            with open("\(pids.path)", "a") as f:
                f.write(str(os.getpid()) + "\\n")
                f.flush()
            while True:
                with open("\(heartbeat.path)", "a") as f:
                    f.write(".")
                time.sleep(0.02)
        time.sleep(0.05)
        if \(timeoutOnAdd ? "True" : "False") and sys.argv[1:4] == ["workspace", "mcp", "add"]:
            time.sleep(5)
        if \(continuousOutput ? "True" : "False"):
            while True:
                os.write(1, b"x" * 8192)
        if sys.argv[1:3] == ["workspace", "list"]:
            os.write(1, b'[{"id":"fixture"}]\\n')
        else:
            os.write(1, b'[]\\n')
        os._exit(0)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = ProcessMulticaWorkspaceMCPCommand.make(executable: executable, addTimeout: 0.2)
        let started = ProcessInfo.processInfo.systemUptime
        if timeoutOnAdd {
            XCTAssertThrowsError(try command.add("askkey", .init(command: "/fixture/askkey", args: ["mcp"])))
        } else if continuousOutput {
            XCTAssertThrowsError(try command.list()) { error in
                XCTAssertEqual(error as? MulticaConnectionError, .invalidResponse)
            }
        } else {
            XCTAssertEqual(try command.list(), [])
        }
        // A successful result must arrive before the production command deadline.
        // Wall time also includes two CLI launches and runner scheduling; the
        // PID and heartbeat checks below verify descendant cleanup directly.
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 26,
                          "Two sequential CLI calls must remain within their bounded deadlines")
        let children = try String(contentsOf: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
        XCTAssertFalse(children.isEmpty)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while children.contains(where: { kill($0, 0) == 0 }), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        for child in children {
            XCTAssertEqual(kill(child, 0), -1, "descendant must have stopped, pid=\(child)")
            XCTAssertEqual(errno, ESRCH)
        }
        let bytes = try Data(contentsOf: heartbeat)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(try Data(contentsOf: heartbeat), bytes)
    }
}
