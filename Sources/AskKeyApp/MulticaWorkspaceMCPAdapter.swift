import Darwin
import Foundation
import AskKeyBroker
import AskKeyCore

struct MulticaMCPServer: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let transport: String
}

struct MulticaMCPConfiguration: Codable, Equatable, Sendable {
    let command: String
    let args: [String]
    let env: [String: String]?

    init(command: String, args: [String], env: [String: String]? = nil) {
        self.command = command
        self.args = args
        self.env = env
    }

    static func make(
        command: String,
        args: [String] = ["mcp"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Self {
        let shared = try MulticaServerConfiguration.make(
            command: command,
            args: args,
            environment: environment,
            homeDirectory: homeDirectory
        )
        return Self(command: shared.command, args: shared.args, env: shared.env)
    }
}

enum MulticaCommandOperation: Equatable {
    case listWorkspaces, selectWorkspace, listServers, addServer, updateServer, removeServer
    case listAgents, assignServer, unassignServer, readAssignment

    var description: String {
        switch self {
        case .listWorkspaces: return appLocalized("listing workspaces")
        case .selectWorkspace: return appLocalized("reading the default workspace")
        case .listServers: return appLocalized("listing MCP servers")
        case .addServer: return appLocalized("adding the MCP server")
        case .updateServer: return appLocalized("updating the MCP server")
        case .removeServer: return appLocalized("removing the MCP server")
        case .listAgents: return appLocalized("listing agents")
        case .assignServer: return appLocalized("assigning the server to an agent")
        case .unassignServer: return appLocalized("removing the server from an agent")
        case .readAssignment: return appLocalized("checking an agent assignment")
        }
    }
}

enum MulticaConnectionError: Error, Equatable, LocalizedError {
    case cliNotInstalled
    case cliCouldNotStart
    case communicationFailed
    case timedOut
    case commandFailed(MulticaCommandOperation)
    case cliNotConfigured
    case notLoggedIn
    case noWorkspace
    case workspaceChoiceRequired
    case permissionDenied
    case unsupportedServer
    case invalidResponse
    case untrustedHelper
    case verificationFailed
    case rollbackFailed
    case creationRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .cliNotInstalled:
            return appLocalized("Multica was not found. Install Multica, then try again.")
        case .cliCouldNotStart:
            return appLocalized("Multica could not start. Reinstall Multica, then try again.")
        case .communicationFailed:
            return appLocalized("Ask Key could not send the setup to Multica. Restart Multica, then try again.")
        case .timedOut:
            return appLocalized("Multica did not respond in time. Restart Multica, then try again.")
        case .commandFailed(let operation):
            return appLocalizedFormat("Multica failed while %@. Contact Ask Key support with this operation name before retrying.", operation.description)
        case .cliNotConfigured:
            return appLocalized("Multica CLI is not set up on this Mac. Run multica setup, then try again.")
        case .notLoggedIn:
            return appLocalized("Multica is not signed in. Sign in to Multica, then try again.")
        case .noWorkspace:
            return appLocalized("This Multica sign-in has no available workspace. Join a workspace, then try again.")
        case .workspaceChoiceRequired:
            return appLocalized("Multica has multiple workspaces, so Ask Key cannot choose one. Select a default workspace in the Multica CLI, then try again.")
        case .permissionDenied:
            return appLocalized("This account cannot manage Multica MCP servers. Ask a workspace admin for permission, then try again.")
        case .unsupportedServer:
            return appLocalized("This Multica server does not support automatic setup. Upgrade Multica, then try again.")
        case .invalidResponse:
            return appLocalized("Multica returned an unrecognized result. Upgrade Multica, then try again.")
        case .untrustedHelper:
            return appLocalized("The Ask Key helper signature or version does not match. Reinstall Ask Key, then try again.")
        case .verificationFailed:
            return appLocalized("Multica did not return a verifiable configuration result. Check the configuration in Multica, then try again.")
        case .rollbackFailed:
            return appLocalized("Multica setup failed and this attempt could not be fully rolled back. Stop retrying and contact Ask Key support.")
        case .creationRecoveryRequired:
            return appLocalized("The Multica server creation outcome is unknown. A server may have been created; the API cannot establish ownership, so no server was automatically deleted. Stop retrying, inspect MCP servers in Multica, and contact Ask Key support for recovery.")
        }
    }
}

struct MulticaWorkspaceInfo: Equatable, Sendable {
    var id: String
    var name: String?
    var displayName: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }
}

struct MulticaAgentTarget: Equatable, Sendable {
    var id: String
    var name: String
}

struct MulticaAssignmentScope: Equatable, Sendable {
    var workspace: MulticaWorkspaceInfo
    var agents: [MulticaAgentTarget]
}

struct MulticaWorkspaceMCPCommand: Sendable {
    var list: @Sendable () throws -> [MulticaMCPServer]
    var add: @Sendable (String, MulticaMCPConfiguration) throws -> MulticaMCPServer
    var update: @Sendable (String, MulticaMCPConfiguration) throws -> MulticaMCPServer
    var remove: @Sendable (String) throws -> Void
    var assignToAllAgents: @Sendable (String) throws -> [String]
    var removeFromAgents: @Sendable (String, [String]) throws -> Void
    var currentWorkspace: @Sendable () throws -> MulticaWorkspaceInfo
    var readAssignmentScope: @Sendable () throws -> MulticaAssignmentScope
    var assignToAgents: @Sendable (String, [String]) throws -> [String]
}

struct MulticaWorkspaceMCPAdapter: Sendable {
    let helperURL: URL
    var helperIsTrusted: @Sendable (URL) -> Bool = CodexHelperSigning.executable.isTrusted
    let command: MulticaWorkspaceMCPCommand
    var serverName = "askkey"
    var removeCreatedServerAfterConfiguration = false
    var recoveryDirectory: URL? = nil

    func preview() throws -> AgentClientPreview {
        let matches = try matchingServers()
        return AgentClientPreview(
            summary: matches.isEmpty ? AgentClient.multica.connectionPreviewSummary
                : appLocalized("An existing Multica configuration was found."),
            connected: false,
            configurationPresent: !matches.isEmpty
        )
    }

    func preparePlan() throws -> AgentOnboardingPlan {
        let matches = try matchingServers()
        if !matches.isEmpty {
            let workspace = (try? command.currentWorkspace())
                ?? MulticaWorkspaceInfo(id: matches[0].id, name: nil)
            return AgentOnboardingPlan(
                client: .multica,
                createdAt: Date(),
                targetIdentity: appLocalized("Confirm the server when you check"),
                scopeSummary: appLocalizedFormat("Workspace %@ already has Ask Key configured.", workspace.displayName),
                agentIDs: [],
                agentNames: [],
                workspaceID: workspace.id,
                workspaceName: workspace.displayName,
                serverID: matches[0].id,
                createsServer: false,
                configurationPresent: true,
                verifiesOnly: true,
                preconditionSummary: appLocalized("This only confirms workspace configuration. It does not prove a real Agent task."),
                activeAgentFingerprint: ""
            )
        }
        let scope = try command.readAssignmentScope()
        let fingerprint = scope.agents.map(\.id).sorted().joined(separator: ",")
        return AgentOnboardingPlan(
            client: .multica,
            createdAt: Date(),
            targetIdentity: appLocalized("Confirm the server when you check"),
            scopeSummary: appLocalizedFormat(
                "Add Ask Key to workspace %@ and assign %d active agents.",
                scope.workspace.displayName,
                scope.agents.count
            ),
            agentIDs: scope.agents.map(\.id),
            agentNames: scope.agents.map(\.name),
            workspaceID: scope.workspace.id,
            workspaceName: scope.workspace.displayName,
            serverID: nil,
            createsServer: true,
            configurationPresent: false,
            verifiesOnly: false,
            preconditionSummary: appLocalized("Ask Key will create the missing server, then assign only the agents shown here."),
            activeAgentFingerprint: fingerprint
        )
    }

    func checkStatus() throws -> AgentCheckReport {
        let matches = try matchingServers()
        if !matches.isEmpty {
            let plan = try preparePlan()
            return AgentCheckReport(
                outcome: .workspaceConfigured,
                targetSummary: plan.workspaceName ?? plan.workspaceID ?? matches[0].id,
                plan: nil,
                failure: nil
            )
        }
        let plan = try preparePlan()
        return AgentCheckReport(
            outcome: .notConfigured,
            targetSummary: plan.workspaceName ?? plan.workspaceID ?? "",
            plan: plan,
            failure: nil
        )
    }

    func commit(_ plan: AgentOnboardingPlan) throws -> AgentApplyReport {
        let existing = try matchingServers()
        if !existing.isEmpty {
            throw AgentOnboardingFailure.planChanged
        }
        guard plan.createsServer else {
            throw MulticaConnectionError.verificationFailed
        }
        guard helperIsTrusted(helperURL) else { throw MulticaConnectionError.untrustedHelper }

        let scope = try command.readAssignmentScope()
        if scope.workspace.id != plan.workspaceID {
            throw AgentOnboardingFailure.planChanged
        }
        let fingerprint = scope.agents.map(\.id).sorted().joined(separator: ",")
        if fingerprint != plan.activeAgentFingerprint {
            throw AgentOnboardingFailure.planChanged
        }

        let operationID = UUID().uuidString
        if let recoveryDirectory {
            try MulticaRecoveryJournal.write(
                .init(
                    operationID: operationID,
                    workspaceID: plan.workspaceID ?? scope.workspace.id,
                    serverName: serverName,
                    agentIDs: plan.agentIDs,
                    phase: "starting",
                    createdServerID: nil,
                    assignedAgentIDs: []
                ),
                to: recoveryDirectory
            )
        }

        let configuration = try MulticaMCPConfiguration.make(command: helperURL.path, args: ["mcp"])
        let created: MulticaMCPServer
        do {
            created = try command.add(serverName, configuration)
        } catch {
            if let recoveryDirectory { try? MulticaRecoveryJournal.write(
                .init(
                    operationID: operationID,
                    workspaceID: plan.workspaceID ?? scope.workspace.id,
                    serverName: serverName,
                    agentIDs: plan.agentIDs,
                    phase: "unknown",
                    createdServerID: nil,
                    assignedAgentIDs: []
                ),
                to: recoveryDirectory
            ) }
            throw error
        }
        if let recoveryDirectory {
            do {
                try MulticaRecoveryJournal.write(
                    .init(
                        operationID: operationID,
                        workspaceID: plan.workspaceID ?? scope.workspace.id,
                        serverName: serverName,
                        agentIDs: plan.agentIDs,
                        phase: "created",
                        createdServerID: created.id,
                        assignedAgentIDs: []
                    ),
                    to: recoveryDirectory
                )
            } catch {
                try? MulticaRecoveryJournal.write(
                    .init(
                        operationID: operationID,
                        workspaceID: plan.workspaceID ?? scope.workspace.id,
                        serverName: serverName,
                        agentIDs: plan.agentIDs,
                        phase: "unknown",
                        createdServerID: created.id,
                        assignedAgentIDs: []
                    ),
                    to: recoveryDirectory
                )
                throw AgentOnboardingFailure.remoteUnknown
            }
        }
        do {
            let readBack = try matchingServers()
            guard readBack.count == 1,
                  readBack[0] == created,
                  created.transport == "stdio" else {
                throw MulticaConnectionError.verificationFailed
            }
            let assigned = try command.assignToAgents(created.id, plan.agentIDs)
            if let recoveryDirectory {
                do {
                    try MulticaRecoveryJournal.write(
                        .init(
                            operationID: operationID,
                            workspaceID: plan.workspaceID ?? scope.workspace.id,
                            serverName: serverName,
                            agentIDs: plan.agentIDs,
                            phase: "assigned",
                            createdServerID: created.id,
                            assignedAgentIDs: assigned
                        ),
                        to: recoveryDirectory
                    )
                } catch {
                    try? MulticaRecoveryJournal.write(
                        .init(
                            operationID: operationID,
                            workspaceID: plan.workspaceID ?? scope.workspace.id,
                            serverName: serverName,
                            agentIDs: plan.agentIDs,
                            phase: "unknown",
                            createdServerID: created.id,
                            assignedAgentIDs: assigned
                        ),
                        to: recoveryDirectory
                    )
                    throw AgentOnboardingFailure.remoteUnknown
                }
            }
            if removeCreatedServerAfterConfiguration { try command.remove(created.id) }
            if let recoveryDirectory { try MulticaRecoveryJournal.clear(in: recoveryDirectory) }
            return AgentApplyReport(
                outcome: .workspaceConfigured,
                changeStatus: .verifiedAndKept,
                failure: nil,
                targetSummary: plan.workspaceName ?? created.id
            )
        } catch {
            if let failure = error as? AgentOnboardingFailure, failure == .remoteUnknown {
                throw failure
            }
            do {
                try command.remove(created.id)
                if let recoveryDirectory { try MulticaRecoveryJournal.clear(in: recoveryDirectory) }
            } catch {
                if let recoveryDirectory {
                    try? MulticaRecoveryJournal.write(
                        .init(
                            operationID: operationID,
                            workspaceID: plan.workspaceID ?? scope.workspace.id,
                            serverName: serverName,
                            agentIDs: plan.agentIDs,
                            phase: "restore_failed",
                            createdServerID: created.id,
                            assignedAgentIDs: []
                        ),
                        to: recoveryDirectory
                    )
                }
                throw MulticaConnectionError.rollbackFailed
            }
            if let error = error as? AgentOnboardingFailure { throw error }
            if let error = error as? MulticaConnectionError { throw error }
            throw MulticaConnectionError.verificationFailed
        }
    }

    func connect() throws -> Bool {
        let existing = try matchingServers()
        if !existing.isEmpty { return true }
        let report = try commit(try preparePlan())
        if let failure = report.failure {
            throw failure
        }
        return true
    }

    private func matchingServers() throws -> [MulticaMCPServer] {
        try command.list().filter { $0.name == serverName }
    }
}

enum ProcessMulticaWorkspaceMCPCommand {
    static func make(
        executable: URL,
        serverName: String = "askkey",
        assignmentAgentName: String? = nil,
        addTimeout: TimeInterval = 12
    ) -> MulticaWorkspaceMCPCommand {
        let selectedWorkspace = MulticaWorkspaceSelection()
        let workspaceID: @Sendable () throws -> String = {
            try selectedWorkspace.info { try resolveWorkspace(executable: executable) }.id
        }
        return MulticaWorkspaceMCPCommand(
            list: {
                try listServers(workspaceID: workspaceID(), executable: executable)
            },
            add: { name, configuration in
                let workspaceID = try workspaceID()
                let before = try listServers(workspaceID: workspaceID, executable: executable)
                let beforeIDs = Set(before.map(\.id))
                let input = try JSONEncoder().encode(configuration)
                let data: Data
                do {
                    data = try run(
                        executable,
                        ["workspace", "mcp", "add", name, workspaceID, "--server-config-stdin", "--output", "json"],
                        input: input, timeout: addTimeout
                    )
                } catch MulticaConnectionError.cliNotInstalled {
                    throw MulticaConnectionError.cliNotInstalled
                } catch MulticaConnectionError.cliCouldNotStart {
                    throw MulticaConnectionError.cliCouldNotStart
                } catch {
                    // A nonzero exit or timeout does not establish that the
                    // remote create failed. Do not retry or infer ownership.
                    throw MulticaConnectionError.creationRecoveryRequired
                }
                if let servers = try? JSONDecoder().decode([MulticaMCPServer].self, from: data),
                   servers.count == 1,
                   let server = servers.first,
                   server.name == name,
                   !beforeIDs.contains(server.id) {
                    return server
                }
                // A newly listed same-name ID could belong to a concurrent
                // user. This CLI exposes no request token or ownership proof;
                // even a single addition cannot be safely deleted as rollback.
                throw MulticaConnectionError.creationRecoveryRequired
            },
            update: { id, configuration in
                let workspaceID = try workspaceID()
                let input = try JSONEncoder().encode(configuration)
                let data = try run(
                    executable,
                    ["workspace", "mcp", "update", id, workspaceID, "--server-config-stdin", "--output", "json"],
                    input: input
                )
                let response = try decodeMutationServer(data, expectedID: id)
                let matches = try listServers(workspaceID: workspaceID, executable: executable)
                    .filter { $0.name == serverName }
                guard matches == [response], response.transport == "stdio" else {
                    throw MulticaConnectionError.verificationFailed
                }
                return response
            },
            remove: { id in
                let workspaceID = try workspaceID()
                try removeServerAndVerify(id, workspaceID: workspaceID, executable: executable)
            },
            assignToAllAgents: { serverID in
                try assignToAllAgents(
                    serverID: serverID,
                    serverName: serverName,
                    assignmentAgentName: assignmentAgentName,
                    workspaceID: workspaceID(),
                    executable: executable
                )
            },
            removeFromAgents: { serverID, agentIDs in
                try removeServer(serverID, fromAgents: agentIDs, workspaceID: workspaceID(), executable: executable)
            },
            currentWorkspace: {
                try selectedWorkspace.info { try resolveWorkspace(executable: executable) }
            },
            readAssignmentScope: {
                let workspace = try selectedWorkspace.info { try resolveWorkspace(executable: executable) }
                let agents = try activeAgents(workspaceID: workspace.id, executable: executable)
                    .map { MulticaAgentTarget(id: $0.id, name: $0.name) }
                return MulticaAssignmentScope(workspace: workspace, agents: agents)
            },
            assignToAgents: { serverID, agentIDs in
                try assignToAgents(
                    serverID: serverID,
                    serverName: serverName,
                    agentIDs: agentIDs,
                    workspaceID: workspaceID(),
                    executable: executable
                )
            }
        )
    }

    private struct Agent: Decodable {
        let id: String
        let name: String
        let archivedAt: String?

        enum CodingKeys: String, CodingKey {
            case id, name
            case archivedAt = "archived_at"
        }
    }

    private struct Workspace: Decodable {
        let id: String
        let name: String?
    }

    private struct AssignedMCPServer: Decodable {
        let id: String
        let name: String
        let transport: String
        let enabled: Bool?
    }

    private static func resolveWorkspace(executable: URL) throws -> MulticaWorkspaceInfo {
        let data = try run(executable, ["workspace", "list", "--output", "json"])
        guard let workspaces = try? JSONDecoder().decode([Workspace].self, from: data) else {
            recordDiagnostic(arguments: ["workspace", "list"], stdout: data, failure: "workspace_schema")
            throw MulticaConnectionError.invalidResponse
        }
        guard !workspaces.isEmpty else { throw MulticaConnectionError.noWorkspace }
        if workspaces.count == 1, let workspace = workspaces.first {
            return MulticaWorkspaceInfo(id: workspace.id, name: workspace.name)
        }
        do {
            let current = try run(executable, ["workspace", "get", "--output", "json"])
            guard let workspace = try? JSONDecoder().decode(Workspace.self, from: current),
                  workspaces.contains(where: { $0.id == workspace.id }) else {
                throw MulticaConnectionError.workspaceChoiceRequired
            }
            let listedName = workspaces.first(where: { $0.id == workspace.id })?.name
            return MulticaWorkspaceInfo(id: workspace.id, name: workspace.name ?? listedName)
        } catch let error as MulticaConnectionError {
            if case .commandFailed(.selectWorkspace) = error { throw MulticaConnectionError.workspaceChoiceRequired }
            throw error
        } catch {
            throw MulticaConnectionError.workspaceChoiceRequired
        }
    }

    private static func resolveWorkspaceID(executable: URL) throws -> String {
        try resolveWorkspace(executable: executable).id
    }

    private static func assignToAgents(
        serverID: String,
        serverName: String,
        agentIDs: [String],
        workspaceID: String,
        executable: URL
    ) throws -> [String] {
        // Frozen IDs only. Do not re-enumerate active agents.
        let additions = try agentIDs.filter { agentID in
            try !assignedServers(agentID: agentID, workspaceID: workspaceID, executable: executable)
                .contains(where: { $0.id == serverID })
        }
        do {
            for agentID in additions {
                _ = try run(executable, ["agent", "mcp", "add", agentID, serverID, "--output", "json", "--workspace-id", workspaceID])
            }
            for agentID in agentIDs {
                guard try assignedServers(agentID: agentID, workspaceID: workspaceID, executable: executable)
                    .contains(where: { $0.id == serverID && $0.name == serverName }) else {
                    throw MulticaConnectionError.verificationFailed
                }
            }
            return additions
        } catch {
            do { try removeServer(serverID, fromAgents: additions, workspaceID: workspaceID, executable: executable) }
            catch { throw MulticaConnectionError.rollbackFailed }
            throw error
        }
    }

    private static func listServers(workspaceID: String, executable: URL) throws -> [MulticaMCPServer] {
        let data = try run(executable, ["workspace", "mcp", "list", workspaceID, "--output", "json"])
        guard let servers = try? JSONDecoder().decode([MulticaMCPServer].self, from: data) else {
            recordDiagnostic(arguments: ["workspace", "mcp", "list"], stdout: data, failure: "server_schema")
            throw MulticaConnectionError.invalidResponse
        }
        return servers
    }

    private static func removeServerAndVerify(_ id: String, workspaceID: String, executable: URL) throws {
        _ = try run(executable, ["workspace", "mcp", "remove", id, workspaceID, "--output", "json"])
        guard try !listServers(workspaceID: workspaceID, executable: executable).contains(where: { $0.id == id }) else {
            throw MulticaConnectionError.rollbackFailed
        }
    }

    private static func activeAgents(workspaceID: String, executable: URL) throws -> [Agent] {
        let data = try run(executable, ["agent", "list", "--output", "json", "--workspace-id", workspaceID])
        guard let agents = try? JSONDecoder().decode([Agent].self, from: data) else {
            throw MulticaConnectionError.invalidResponse
        }
        return agents.filter { $0.archivedAt == nil }
    }

    private static func assignToAllAgents(
        serverID: String,
        serverName: String,
        assignmentAgentName: String?,
        workspaceID: String,
        executable: URL
    ) throws -> [String] {
        let active = try activeAgents(workspaceID: workspaceID, executable: executable)
        let targets = assignmentAgentName.map { name in active.filter { $0.name == name } } ?? active
        guard !targets.isEmpty else { throw MulticaConnectionError.verificationFailed }
        let additions = try targets.filter {
            try !assignedServers(agentID: $0.id, workspaceID: workspaceID, executable: executable)
                .contains(where: { $0.id == serverID })
        }
        do {
            for agent in additions {
                _ = try run(executable, ["agent", "mcp", "add", agent.id, serverID, "--output", "json", "--workspace-id", workspaceID])
            }
            for agent in targets {
                guard try assignedServers(agentID: agent.id, workspaceID: workspaceID, executable: executable)
                    .contains(where: { $0.id == serverID && $0.name == serverName }) else {
                    throw MulticaConnectionError.verificationFailed
                }
            }
            return additions.map(\.id)
        } catch {
            do { try removeServer(serverID, fromAgents: additions.map(\.id), workspaceID: workspaceID, executable: executable) }
            catch { throw MulticaConnectionError.rollbackFailed }
            throw error
        }
    }

    private static func assignedServers(agentID: String, workspaceID: String, executable: URL) throws -> [AssignedMCPServer] {
        let data = try run(executable, ["agent", "mcp", "list", agentID, "--output", "json", "--workspace-id", workspaceID])
        guard let servers = try? JSONDecoder().decode([AssignedMCPServer].self, from: data) else {
            throw MulticaConnectionError.invalidResponse
        }
        return servers
    }

    private static func removeServer(
        _ serverID: String,
        fromAgents agentIDs: [String],
        workspaceID: String,
        executable: URL
    ) throws {
        for agentID in agentIDs {
            let assigned = try assignedServers(agentID: agentID, workspaceID: workspaceID, executable: executable)
            if assigned.contains(where: { $0.id == serverID }) {
                _ = try run(executable, ["agent", "mcp", "remove", agentID, serverID, "--output", "json", "--workspace-id", workspaceID])
            }
            guard try !assignedServers(agentID: agentID, workspaceID: workspaceID, executable: executable)
                .contains(where: { $0.id == serverID }) else {
                throw MulticaConnectionError.rollbackFailed
            }
        }
    }

    private static func decodeMutationServer(_ data: Data, expectedID: String) throws -> MulticaMCPServer {
        if let server = try? JSONDecoder().decode(MulticaMCPServer.self, from: data), server.id == expectedID {
            return server
        }
        if let servers = try? JSONDecoder().decode([MulticaMCPServer].self, from: data),
           servers.count == 1,
           let server = servers.first,
           server.id == expectedID {
            return server
        }
        throw MulticaConnectionError.invalidResponse
    }

    private struct NetworkUnavailable: Error {}

    private static func run(_ executable: URL, _ arguments: [String], input: Data? = nil, timeout: TimeInterval = 12) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + (timeout.isFinite && timeout > 0 ? timeout : 12)
        let readOnlyPrefixes = [
            ["workspace", "list"], ["workspace", "get"], ["workspace", "mcp", "list"],
            ["agent", "list"], ["agent", "mcp", "list"],
        ]
        let canRetry = input == nil && readOnlyPrefixes.contains { arguments.starts(with: $0) }
        let delays: [TimeInterval] = [0.25, 0.75]
        var retries = 0
        while true {
            if RestrictedProcessCancellation.current?() == true {
                throw AgentOnboardingFailure.cancelled
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MulticaConnectionError.timedOut
            }
            do {
                return try runAttempt(executable, arguments, input: input, deadline: deadline)
            } catch is NetworkUnavailable {
                // macOS can reject the first TCP connection while refreshing an
                // already-allowed app's local-network UUID cache after an update.
                // Retry only reads, within the original deadline, never mutations.
                guard canRetry, retries < delays.count else {
                    throw MulticaConnectionError.commandFailed(operation(for: arguments))
                }
                let resumeAt = min(deadline, ProcessInfo.processInfo.systemUptime + delays[retries])
                retries += 1
                while ProcessInfo.processInfo.systemUptime < resumeAt {
                    if RestrictedProcessCancellation.current?() == true {
                        throw AgentOnboardingFailure.cancelled
                    }
                    Thread.sleep(forTimeInterval: min(0.01, max(0, resumeAt - ProcessInfo.processInfo.systemUptime)))
                }
            }
        }
    }

    private static func runAttempt(_ executable: URL, _ arguments: [String], input: Data?, deadline: TimeInterval) throws -> Data {
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            NSLog("AskKey Multica operation=%@ duration_ms=%ld", operation(for: arguments).description,
                  Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            recordDiagnostic(arguments: arguments, failure: "CLI executable is unavailable")
            throw MulticaConnectionError.cliNotInstalled
        }
        let output = Pipe()
        let errors = Pipe()
        let standardInput = Pipe()
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("MULTICA_")
        }
        environment["HOME"] = userHome.path
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        let inFD = standardInput.fileHandleForWriting.fileDescriptor
        defer {
            for handle in [output.fileHandleForReading, output.fileHandleForWriting,
                           errors.fileHandleForReading, errors.fileHandleForWriting,
                           standardInput.fileHandleForReading, standardInput.fileHandleForWriting] {
                try? handle.close()
            }
        }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(errFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(inFD, F_SETFL, O_NONBLOCK) != -1,
              fcntl(inFD, F_SETNOSIGPIPE, 1) != -1 else {
            recordDiagnostic(arguments: arguments, failure: "pipe_setup", systemError: errno)
            throw MulticaConnectionError.communicationFailed
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw MulticaConnectionError.cliCouldNotStart }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw MulticaConnectionError.cliCouldNotStart }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, userHome.path) == 0,
              posix_spawn_file_actions_adddup2(&actions, standardInput.fileHandleForReading.fileDescriptor, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errors.fileHandleForWriting.fileDescriptor, STDERR_FILENO) == 0 else {
            throw MulticaConnectionError.cliCouldNotStart
        }
        var argv = ([executable.path] + arguments).map { strdup($0) }
        var envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw MulticaConnectionError.cliCouldNotStart
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        let spawned = argv.withUnsafeMutableBufferPointer { args in
            envp.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard spawned == 0, pid > 0 else {
            recordDiagnostic(arguments: arguments, failure: "spawn", systemError: spawned)
            throw MulticaConnectionError.cliCouldNotStart
        }
#if DEBUG
        OnboardingBoundaryObserver.note(.multicaCLI)
#endif
        defer { stop(pid) }
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        try standardInput.fileHandleForReading.close()
        let inputBytes = input ?? Data()
        var inputOffset = 0
        var inputClosed = false
        var data = Data()
        var errorData = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var exited = false
        var terminationStatus: Int32 = -1
        var stage = "stdin_close"
        var systemError: Int32?
        do {
            while true {
                if RestrictedProcessCancellation.current?() == true {
                    throw AgentOnboardingFailure.cancelled
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw MulticaConnectionError.timedOut
                }
                if !exited {
                    stage = "waitid"
                    var info = siginfo_t()
                    let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                    guard result == 0 || errno == EINTR else {
                        systemError = errno
                        throw MulticaConnectionError.communicationFailed
                    }
                    if result == 0, info.si_pid == pid {
                        exited = true
                        terminationStatus = info.si_code == CLD_EXITED ? info.si_status : -1
                    }
                }
                if !inputClosed {
                    if inputOffset == inputBytes.count {
                        stage = "stdin_close"
                        try standardInput.fileHandleForWriting.close()
                        inputClosed = true
                    } else {
                        stage = "stdin_write"
                        let count = inputBytes.withUnsafeBytes { bytes in
                            Darwin.write(inFD, bytes.baseAddress!.advanced(by: inputOffset), min(8192, inputBytes.count - inputOffset))
                        }
                        if count > 0 { inputOffset += count }
                        else if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                            systemError = errno
                            throw MulticaConnectionError.communicationFailed
                        }
                    }
                }
                var readAny = false
                for descriptor in [outFD, errFD] {
                    stage = descriptor == outFD ? "stdout_read" : "stderr_read"
                    let count = Darwin.read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        readAny = true
                        let existingCount = descriptor == outFD ? data.count : errorData.count
                        guard existingCount + count <= 1_048_576 else { throw MulticaConnectionError.invalidResponse }
                        if descriptor == outFD { data.append(contentsOf: buffer.prefix(count)) }
                        else { errorData.append(contentsOf: buffer.prefix(count)) }
                    } else if count < 0, errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        systemError = errno
                        throw MulticaConnectionError.communicationFailed
                    }
                }
                // A descendant holding either pipe cannot extend the leader's life.
                if exited && !readAny { break }
                if !readAny { Thread.sleep(forTimeInterval: 0.005) }
            }
        } catch {
            // These enums contain only application-defined cases, never CLI output.
            let category: String
            if let error = error as? MulticaConnectionError { category = String(describing: error) }
            else if let error = error as? AgentOnboardingFailure { category = String(describing: error) }
            else { category = "unexpected" }
            recordDiagnostic(arguments: arguments, stdout: data, stderr: errorData,
                             failure: category, stage: stage, systemError: systemError,
                             durationMilliseconds: Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))
            throw error
        }
        recordDiagnostic(
            arguments: arguments,
            terminationStatus: terminationStatus,
            stdout: data,
            stderr: errorData,
            failure: terminationStatus == 0 ? nil : diagnosticFailureCategory(errorData + data),
            durationMilliseconds: Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        )
        guard terminationStatus == 0 else {
            let rawMessage = String(decoding: errorData + data, as: UTF8.self)
            let message = rawMessage.lowercased()
            // v0.4.43 intentionally hides the underlying socket error unless
            // --debug is enabled. Recognize its ordinary network-error copy;
            // do not enable verbose output that could contain private details.
            if message.contains("could not connect to the multica server.")
                || message.contains("could not reach the multica server.")
                || (message.contains("dial tcp") && message.contains("connect: no route to host")) {
                throw NetworkUnavailable()
            }
            if message.contains("permission") || message.contains("not authorized") || message.contains("forbidden") || message.contains("admin") {
                throw MulticaConnectionError.permissionDenied
            }
            if message.contains("not logged in") || message.contains("unauthenticated") || message.contains("missing token") {
                throw MulticaConnectionError.notLoggedIn
            }
            if message.contains("no server configured") && message.contains("multica setup") {
                throw MulticaConnectionError.cliNotConfigured
            }
            if message.contains("unsupported") || message.contains("unknown command") { throw MulticaConnectionError.unsupportedServer }
            throw MulticaConnectionError.commandFailed(operation(for: arguments))
        }
        return data
    }

    private static func recordDiagnostic(
        arguments: [String],
        terminationStatus: Int32? = nil,
        stdout: Data = Data(),
        stderr: Data = Data(),
        failure: String? = nil,
        stage: String? = nil,
        systemError: Int32? = nil,
        durationMilliseconds: Int? = nil
    ) {
        // Keep installed builds diagnosable without recording arguments, IDs,
        // configuration, credentials, or the CLI's stdout/stderr contents.
        let validJSON = (try? JSONSerialization.jsonObject(with: stdout, options: [.fragmentsAllowed])) != nil
        NSLog("AskKey Multica operation=%@ exit=%@ stdout_bytes=%ld stderr_bytes=%ld valid_json=%d failure=%@",
              operation(for: arguments).description, terminationStatus.map(String.init) ?? "not-exited",
              stdout.count, stderr.count, validJSON ? 1 : 0, failure ?? "none")
        if Bundle.main.bundleURL.pathExtension == "app" {
            let directory = VaultConfiguration.daemonSocketURL.deletingLastPathComponent()
                .appendingPathComponent("multica-process-diagnostics", isDirectory: true)
            _ = MulticaProcessDiagnosticLog.write(.init(
                operation: operation(for: arguments).description,
                exit: terminationStatus,
                stdoutBytes: stdout.count,
                stderrBytes: stderr.count,
                validJSON: validJSON,
                failure: failure,
                stage: stage,
                systemError: systemError,
                durationMilliseconds: durationMilliseconds
            ), directory: directory)
        }
        guard writeDiagnosticLog(
            arguments: arguments,
            terminationStatus: terminationStatus,
            stdout: stdout,
            stderr: stderr,
            failure: failure
        ) else {
            NSLog("Ask Key could not write the Multica diagnostic log")
            return
        }
    }

    // Only fixed categories cross the diagnostic boundary; the original text
    // can contain tokens, URLs, or workspace data and must never be persisted.
    private static func diagnosticFailureCategory(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        let markers: [(String, String)] = [
            ("could not reach the multica server.", "network_offline"),
            ("could not connect to the multica server.", "network_unavailable"),
            ("operation not permitted", "operation_not_permitted"),
            ("permission denied", "permission_denied"),
            ("connection refused", "connection_refused"),
            ("connection reset", "connection_reset"),
            ("no route to host", "no_route"),
            ("network is unreachable", "network_unreachable"),
            ("no such host", "dns"),
            ("timeout", "timeout"),
            ("deadline exceeded", "timeout"),
            ("not logged in", "not_logged_in"),
            ("unauthenticated", "unauthenticated"),
            ("eof", "unexpected_eof"),
        ]
        return markers.first { text.contains($0.0) }?.1 ?? "nonzero_exit"
    }

    private static func writeDiagnosticLog(
        arguments: [String],
        terminationStatus: Int32? = nil,
        stdout: Data = Data(),
        stderr: Data = Data(),
        failure: String? = nil
    ) -> Bool {
        #if DEBUG
        guard Bundle.main.bundleURL.pathExtension == "app" else { return true }
        let directory = VaultConfiguration.daemonSocketURL.deletingLastPathComponent()
            .appendingPathComponent("multica-cli-logs", isDirectory: true)
        let makeDirectory = directory.path.withCString { mkdir($0, S_IRWXU) }
        if makeDirectory != 0, errno != EEXIST { return false }
        var directoryInfo = stat()
        guard directory.path.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directory.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else { return false }
        let body = """
        command: multica \(arguments.joined(separator: " "))
        exit: \(terminationStatus.map(String.init) ?? "not-started")
        failure: \(failure ?? "none")
        stdout:
        \(String(decoding: stdout, as: UTF8.self))
        stderr:
        \(String(decoding: stderr, as: UTF8.self))
        """
        let identifier = UUID().uuidString
        let temporaryFile = directory.appendingPathComponent(".\(identifier).tmp")
        let finalFile = directory.appendingPathComponent("\(identifier).log")
        let descriptor = temporaryFile.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return false }
        let bytes = Data(body.utf8)
        let wrote = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        let synced = fsync(descriptor) == 0
        let closed = Darwin.close(descriptor) == 0
        guard wrote, synced, closed else {
            temporaryFile.path.withCString { _ = Darwin.unlink($0) }
            return false
        }
        let renamed = temporaryFile.path.withCString { source in
            finalFile.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else {
            temporaryFile.path.withCString { _ = Darwin.unlink($0) }
            return false
        }
        return true
        #else
        return true
        #endif
    }

    private static func operation(for arguments: [String]) -> MulticaCommandOperation {
        if arguments.starts(with: ["workspace", "list"]) { return .listWorkspaces }
        if arguments.starts(with: ["workspace", "get"]) { return .selectWorkspace }
        if arguments.starts(with: ["workspace", "mcp", "list"]) { return .listServers }
        if arguments.starts(with: ["workspace", "mcp", "add"]) { return .addServer }
        if arguments.starts(with: ["workspace", "mcp", "update"]) { return .updateServer }
        if arguments.starts(with: ["workspace", "mcp", "remove"]) { return .removeServer }
        if arguments.starts(with: ["agent", "list"]) { return .listAgents }
        if arguments.starts(with: ["agent", "mcp", "add"]) { return .assignServer }
        if arguments.starts(with: ["agent", "mcp", "remove"]) { return .unassignServer }
        if arguments.starts(with: ["agent", "mcp", "list"]) { return .readAssignment }
        return .listServers
    }

    private static func stop(_ pid: pid_t) {
        // WNOWAIT keeps this leader unreaped, reserving its PID until its own
        // spawn-created group is killed. Never signal the host App's group.
        // Descendants that deliberately call setsid/setpgid can escape this group.
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while ProcessInfo.processInfo.systemUptime < deadline {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno != EINTR) { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

private final class MulticaWorkspaceSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var workspace: MulticaWorkspaceInfo?

    func id(resolve: () throws -> String) throws -> String {
        try info {
            MulticaWorkspaceInfo(id: try resolve(), name: nil)
        }.id
    }

    func info(resolve: () throws -> MulticaWorkspaceInfo) throws -> MulticaWorkspaceInfo {
        lock.lock()
        defer { lock.unlock() }
        if let workspace { return workspace }
        let resolved = try resolve()
        workspace = resolved
        return resolved
    }
}

enum MulticaRecoveryJournal {
    struct Record: Codable, Equatable, Sendable {
        var operationID: String
        var workspaceID: String
        var serverName: String
        var agentIDs: [String]
        var phase: String
        var createdServerID: String?
        var assignedAgentIDs: [String]
    }

    static func load(from directory: URL) -> Record? {
        let file = directory.appendingPathComponent("pending.json")
        var info = stat()
        guard file.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func write(_ record: Record, to directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let chmodOK = directory.path.withCString { chmod($0, S_IRWXU) == 0 }
        guard chmodOK else { throw MulticaConnectionError.communicationFailed }
        var directoryInfo = stat()
        guard directory.path.withCString({ lstat($0, &directoryInfo) }) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR else {
            throw MulticaConnectionError.communicationFailed
        }
        let file = directory.appendingPathComponent("pending.json")
        var fileInfo = stat()
        if file.path.withCString({ lstat($0, &fileInfo) }) == 0 {
            guard fileInfo.st_mode & S_IFMT == S_IFREG else {
                throw MulticaConnectionError.communicationFailed
            }
        }
        #if DEBUG
        try testWriteInterceptor?(record)
        #endif
        let data = try JSONEncoder().encode(record)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = temporary.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw MulticaConnectionError.communicationFailed }
        var openDescriptor = true
        defer {
            if openDescriptor { Darwin.close(fd) }
        }
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else {
                    guard buffer.isEmpty else { throw MulticaConnectionError.communicationFailed }
                    return
                }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw MulticaConnectionError.communicationFailed }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw MulticaConnectionError.communicationFailed }
            let closed = Darwin.close(fd)
            openDescriptor = false
            guard closed == 0 else { throw MulticaConnectionError.communicationFailed }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        let renamed = file.path.withCString { destination in
            temporary.path.withCString { source in
                Darwin.rename(source, destination)
            }
        }
        if renamed != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw MulticaConnectionError.communicationFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

#if DEBUG
    static var testWriteInterceptor: ((Record) throws -> Void)?
#endif

    static func clear(in directory: URL) throws {
        let file = directory.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }
}
