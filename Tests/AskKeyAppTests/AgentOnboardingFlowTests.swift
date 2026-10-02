import Foundation
import XCTest
@testable import AskKeyApp

@MainActor
final class AgentOnboardingFlowTests: XCTestCase {
    func testMulticaExistingConfigurationCheckHasZeroMutation() throws {
        let probe = MutationProbe(existing: true)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command
        )
        let report = try adapter.checkStatus()
        XCTAssertEqual(report.outcome, .workspaceConfigured)
        XCTAssertNil(report.plan)
        XCTAssertEqual(probe.addCount, 0)
        XCTAssertEqual(probe.assignCount, 0)
        XCTAssertEqual(probe.scopeCount, 0)
    }

    func testMulticaMissingConfigurationBuildsConfirmablePlan() throws {
        let probe = MutationProbe(existing: false)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command
        )
        let report = try adapter.checkStatus()
        XCTAssertEqual(report.outcome, .notConfigured)
        XCTAssertEqual(report.plan?.agentIDs, ["agent-1", "agent-2"])
        XCTAssertEqual(report.plan?.workspaceName, "Studio")
        XCTAssertEqual(probe.addCount, 0)
        XCTAssertEqual(probe.assignCount, 0)
        XCTAssertEqual(probe.scopeCount, 1)
    }

    func testMulticaCommitStopsWhenAgentScopeChanges() throws {
        let probe = MutationProbe(existing: false, laterAgents: ["agent-1", "agent-2", "agent-3"])
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        XCTAssertThrowsError(try adapter.commit(plan)) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .planChanged)
        }
        XCTAssertEqual(probe.addCount, 0)
        XCTAssertEqual(probe.assignCount, 0)
    }

    func testMulticaCommitAssignsOnlyFrozenAgentIDs() throws {
        let probe = MutationProbe(existing: false)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        let report = try adapter.commit(plan)
        XCTAssertEqual(report.outcome, .workspaceConfigured)
        XCTAssertEqual(report.changeStatus, .verifiedAndKept)
        XCTAssertEqual(probe.assignedIDs, ["agent-1", "agent-2"])
        XCTAssertFalse(probe.assignedIDs.contains("agent-3"))
    }

    func testMulticaUnknownCreateKeepsRecoveryRecordWithoutDeleting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-onboarding-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent("recovery", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = MutationProbe(existing: false, createError: MulticaConnectionError.creationRecoveryRequired)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command,
            recoveryDirectory: recovery
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        XCTAssertThrowsError(try adapter.commit(plan))
        XCTAssertEqual(probe.removeCount, 0)
        let record = try XCTUnwrap(MulticaRecoveryJournal.load(from: recovery))
        XCTAssertEqual(record.phase, "unknown")
    }

    func testMulticaCommitTreatsAppearedAskKeyAsPlanChanged() throws {
        let probe = MutationProbe(existing: false)
        let adapter = MulticaWorkspaceMCPAdapter(
            helperURL: URL(fileURLWithPath: "/Applications/Ask Key.app/Contents/Helpers/askkey"),
            helperIsTrusted: { _ in true },
            command: probe.command
        )
        let plan = try XCTUnwrap(try adapter.checkStatus().plan)
        probe.appearAskKey()
        XCTAssertThrowsError(try adapter.commit(plan)) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .planChanged)
        }
        XCTAssertEqual(probe.addCount, 0)
        XCTAssertEqual(probe.assignCount, 0)
    }

    func testPendingRecoveryLoadsRestoreFailedFromPhase() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-onboarding-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent(
            "client-backups/multica-recovery",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try MulticaRecoveryJournal.write(
            .init(
                operationID: "op-restore",
                workspaceID: "ws-1",
                serverName: "askkey",
                agentIDs: ["agent-1"],
                phase: "restore_failed",
                createdServerID: "created-id",
                assignedAgentIDs: []
            ),
            to: recovery
        )
        let coordinator = AgentOnboardingCoordinator(operations: .inactive)
        AgentOnboardingRuntime.adoptPendingRecovery(into: coordinator, supportDirectory: root)
        let session = coordinator.session(for: .multica)
        XCTAssertEqual(session.attempt.phase, .recoveryRequired)
        XCTAssertEqual(session.attempt.changeStatus, .restoreFailed)
        XCTAssertEqual(session.attempt.failure, .restoreFailed)
    }

    func testPendingRecoveryLoadsWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-onboarding-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent(
            "client-backups/multica-recovery",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try MulticaRecoveryJournal.write(
            .init(
                operationID: "op-1",
                workspaceID: "ws-1",
                serverName: "askkey",
                agentIDs: ["agent-1"],
                phase: "unknown",
                createdServerID: nil,
                assignedAgentIDs: []
            ),
            to: recovery
        )
        let coordinator = AgentOnboardingCoordinator(operations: .inactive)
        AgentOnboardingRuntime.adoptPendingRecovery(into: coordinator, supportDirectory: root)
        let session = coordinator.session(for: .multica)
        XCTAssertEqual(session.attempt.phase, .recoveryRequired)
        XCTAssertEqual(session.attempt.changeStatus, .remoteUnknown)
        XCTAssertEqual(session.attempt.failure, .remoteUnknown)
    }

    func testWorkspaceDisplayNameFallsBackToID() {
        XCTAssertEqual(MulticaWorkspaceInfo(id: "ws-1", name: nil).displayName, "ws-1")
        XCTAssertEqual(MulticaWorkspaceInfo(id: "ws-1", name: "  ").displayName, "ws-1")
        XCTAssertEqual(MulticaWorkspaceInfo(id: "ws-1", name: "Studio").displayName, "Studio")
    }
}

final class MutationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var servers: [MulticaMCPServer]
    private var agents: [MulticaAgentTarget]
    private let laterAgents: [String]
    private let createError: Error?
    private(set) var addCount = 0
    private(set) var assignCount = 0
    private(set) var scopeCount = 0
    private(set) var removeCount = 0
    private(set) var assignedIDs: [String] = []

    init(
        existing: Bool,
        laterAgents: [String] = [],
        createError: Error? = nil
    ) {
        servers = existing ? [MulticaMCPServer(id: "server-1", name: "askkey", transport: "stdio")] : []
        agents = [
            MulticaAgentTarget(id: "agent-1", name: "开发"),
            MulticaAgentTarget(id: "agent-2", name: "审查"),
        ]
        self.laterAgents = laterAgents
        self.createError = createError
    }

    func appearAskKey() {
        lock.withLock {
            servers = [MulticaMCPServer(id: "server-1", name: "askkey", transport: "stdio")]
        }
    }

    var command: MulticaWorkspaceMCPCommand {
        MulticaWorkspaceMCPCommand(
            list: { self.lock.withLock { self.servers } },
            add: { name, _ in
                self.lock.lock()
                self.addCount += 1
                if let createError = self.createError {
                    self.lock.unlock()
                    throw createError
                }
                let server = MulticaMCPServer(id: "created-id", name: name, transport: "stdio")
                self.servers = [server]
                self.lock.unlock()
                return server
            },
            update: { id, _ in MulticaMCPServer(id: id, name: "askkey", transport: "stdio") },
            remove: { _ in self.lock.withLock { self.removeCount += 1 } },
            assignToAllAgents: { _ in
                self.lock.withLock { self.assignCount += 1 }
                return []
            },
            removeFromAgents: { _, _ in },
            currentWorkspace: { MulticaWorkspaceInfo(id: "ws-1", name: "Studio") },
            readAssignmentScope: {
                self.lock.lock()
                self.scopeCount += 1
                if !self.laterAgents.isEmpty, self.scopeCount > 1 {
                    self.agents = self.laterAgents.map { MulticaAgentTarget(id: $0, name: $0) }
                }
                let scope = MulticaAssignmentScope(
                    workspace: MulticaWorkspaceInfo(id: "ws-1", name: "Studio"),
                    agents: self.agents
                )
                self.lock.unlock()
                return scope
            },
            assignToAgents: { _, agentIDs in
                self.lock.withLock {
                    self.assignCount += 1
                    self.assignedIDs = agentIDs
                }
                return agentIDs
            }
        )
    }
}
