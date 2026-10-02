import Foundation

@available(*, deprecated, message: "Remote vault socket transport is no longer the App/CLI path; Broker is. Kept for compatibility tests.")
public enum RemoteVaultError: Error, LocalizedError {
    /// The daemon ran the operation and returned an error (e.g. secret not found).
    case daemon(String)
    /// The daemon returned a response that doesn't match the request.
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .daemon(let message): return message
        case .unexpectedResponse: return "Unexpected response from the AskKey daemon."
        }
    }
}

/// A `VaultService` that runs every operation in the daemon instead of in this
/// process, so the CLI and MCP server never hold the vault key (ADR 0014).
///
/// The actual byte transport is injected: the socket client provides one in
/// production; tests inject an in-process dispatcher so the whole request →
/// dispatch → response → result loop is exercised without a socket.
@available(*, deprecated, message: "Remote vault socket transport is no longer the App/CLI path; Broker is. Kept for compatibility tests.")
public final class RemoteVaultService: VaultService {
    public typealias Transport = (VaultRequest) throws -> VaultResponse

    private let transport: Transport

    public init(transport: @escaping Transport) {
        self.transport = transport
    }

    private func send(_ request: VaultRequest) throws -> VaultResponse {
        let response = try transport(request)
        if case let .failure(message) = response {
            throw RemoteVaultError.daemon(message)
        }
        return response
    }

    public func unlock() throws {
        _ = try send(.unlock)
    }

    public func addProject(name: String, icon: String?) throws -> Project {
        guard case let .project(project) = try send(.addProject(name: name, icon: icon)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return project
    }

    public func project(id: String) throws -> Project {
        guard case let .project(project) = try send(.projectByID(id)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return project
    }

    public func project(name: String) throws -> Project? {
        guard case let .optionalProject(project) = try send(.projectByName(name)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return project
    }

    public func resolveProject(name: String?) throws -> Project {
        guard case let .project(project) = try send(.resolveProject(name: name)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return project
    }

    public func listProjects() throws -> [Project] {
        guard case let .projects(projects) = try send(.listProjects) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return projects
    }

    public func deleteProjectIncludingContents(id: String) throws {
        _ = try send(.deleteProjectIncludingContents(id: id))
    }

    public func activeProjectId() throws -> String? {
        guard case let .optionalString(id) = try send(.activeProjectID) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return id
    }

    public func setActiveProject(id: String?) throws {
        _ = try send(.setActiveProject(id: id))
    }

    public func addEnvironment(name: String, projectId: String, color: String?) throws -> VaultEnvironment {
        guard case let .environments(environments) = try send(.addEnvironment(name: name, projectId: projectId, color: color)),
              let environment = environments.first else {
            throw RemoteVaultError.unexpectedResponse
        }
        return environment
    }

    public func deleteEnvironmentIncludingContents(name: String, projectId: String) throws {
        _ = try send(.deleteEnvironmentIncludingContents(name: name, projectId: projectId))
    }

    public func add(name: String, value: String, description: String?, icon: String?, category: SecretCategory?, projectId: String, environmentName: String?) throws -> Secret {
        guard case let .secret(secret) = try send(.add(name: name, value: value, description: description, icon: icon, category: category, projectId: projectId, environmentName: environmentName)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return secret
    }

    public func get(name: String, projectId: String, environmentName: String?) throws -> Secret {
        guard case let .secret(secret) = try send(.get(name: name, projectId: projectId, environmentName: environmentName)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return secret
    }

    public func set(name: String, value: String, projectId: String, environmentName: String?) throws -> Secret {
        guard case let .secret(secret) = try send(.set(name: name, value: value, projectId: projectId, environmentName: environmentName)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return secret
    }

    public func delete(name: String, projectId: String) throws {
        _ = try send(.delete(name: name, projectId: projectId))
    }

    public func list(projectId: String, environmentName: String?) throws -> [Secret] {
        guard case let .secrets(secrets) = try send(.list(projectId: projectId, environmentName: environmentName)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return secrets
    }

    public func listInfo(projectId: String) throws -> [SecretInfo] {
        guard case let .secretInfos(infos) = try send(.listInfo(projectId: projectId)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return infos
    }

    public func listEnvironments(projectId: String) throws -> [VaultEnvironment] {
        guard case let .environments(environments) = try send(.listEnvironments(projectId: projectId)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return environments
    }

    public func setActiveEnvironment(name: String?, projectId: String) throws {
        _ = try send(.setActiveEnvironment(name: name, projectId: projectId))
    }

    public func importEnv(pairs: [(name: String, value: String)], projectId: String, environmentName: String?, overwrite: Bool) throws -> ImportSummary {
        let wirePairs = pairs.map { EnvPair(name: $0.name, value: $0.value) }
        guard case let .importSummary(summary) = try send(.importEnv(pairs: wirePairs, projectId: projectId, environmentName: environmentName, overwrite: overwrite)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return summary
    }

    public func createProjectFromEnv(name: String, environmentName: String, pairs: [(name: String, value: String)], overwrite: Bool) throws -> (project: Project, environmentName: String, summary: ImportSummary) {
        let wirePairs = pairs.map { EnvPair(name: $0.name, value: $0.value) }
        guard case let .projectImport(result) = try send(.createProjectFromEnv(
            name: name,
            environmentName: environmentName,
            pairs: wirePairs,
            overwrite: overwrite
        )) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return (result.project, result.environmentName, result.summary)
    }

    public func setAgentAccess(name: String, projectId: String, policy: AgentAccessPolicy) throws {
        _ = try send(.setAgentAccess(name: name, projectId: projectId, policy: policy))
    }

    public func secretCount(projectId: String, environmentName: String?) throws -> Int {
        guard case let .count(count) = try send(.secretCount(projectId: projectId, environmentName: environmentName)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return count
    }

    public func totalSecretCount(projectId: String) throws -> Int {
        guard case let .count(count) = try send(.totalSecretCount(projectId: projectId)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return count
    }

    public func listActivity(limit: Int, filter: ActivityFilter) throws -> [ActivityLogEntry] {
        guard case let .activity(entries) = try send(.listActivity(limit: limit, filter: filter)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return entries
    }

    public func export(projectId: String, passphrase: String?) throws -> Data {
        guard case let .data(data) = try send(.export(projectId: projectId, passphrase: passphrase)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return data
    }

    public func exportExcludingApprovalTier(projectId: String, passphrase: String?) throws -> (data: Data, skippedNames: [String]) {
        guard case let .exportResult(result) = try send(.exportExcludingApprovalTier(projectId: projectId, passphrase: passphrase)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return (result.data, result.skippedNames)
    }

    public func decryptExport(_ envelope: Data, passphrase: String) throws -> [String: String] {
        guard case let .dictionary(dictionary) = try send(.decryptExport(envelope: envelope, passphrase: passphrase)) else {
            throw RemoteVaultError.unexpectedResponse
        }
        return dictionary
    }

    /// Logging is best-effort, mirroring the local `Vault.logAccess` (non-throwing).
    /// `agent` is intentionally not sent — the daemon stamps the caller's agent
    /// from the kernel peer-PID, which the client cannot forge.
    public func logAccess(secretName: String, projectName: String, environmentName: String, source: ActivityLogEntry.AccessSource, agent: String? = nil, peerTeamID: String? = nil, action: ActivityLogEntry.Action = .read) {
        // `agent` and `peerTeamID` are intentionally not sent — the daemon stamps
        // both from the kernel peer-PID / its code signature, which the client
        // cannot forge.
        _ = try? send(.logAccess(secretName: secretName, projectName: projectName, environmentName: environmentName, source: source, action: action))
    }
}
