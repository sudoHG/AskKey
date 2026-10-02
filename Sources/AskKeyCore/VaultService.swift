import Foundation

/// The vault operations that out-of-process clients (the CLI and the MCP server)
/// depend on. `Vault` is the in-process implementation used by the menu-bar app
/// (the daemon). A socket-backed `RemoteVaultService` will conform to the same
/// protocol so the CLI and MCP server can run without ever holding the vault key
/// (ADR 0014, phase 2). This protocol is the seam that swap targets.
///
/// Requirements list every parameter explicitly — protocol requirements cannot
/// carry default argument values — so callers pass all arguments. `Vault`'s
/// methods (which do declare defaults) satisfy these signatures unchanged.
public protocol VaultService: AnyObject {
    func unlock() throws

    func addProject(name: String, icon: String?) throws -> Project
    func project(id: String) throws -> Project
    func project(name: String) throws -> Project?
    func resolveProject(name: String?) throws -> Project
    func listProjects() throws -> [Project]
    func deleteProjectIncludingContents(id: String) throws
    func activeProjectId() throws -> String?
    func setActiveProject(id: String?) throws

    func addEnvironment(name: String, projectId: String, color: String?) throws -> VaultEnvironment
    func deleteEnvironmentIncludingContents(name: String, projectId: String) throws

    func add(
        name: String,
        value: String,
        description: String?,
        icon: String?,
        category: SecretCategory?,
        projectId: String,
        environmentName: String?
    ) throws -> Secret
    func get(name: String, projectId: String, environmentName: String?) throws -> Secret
    func set(name: String, value: String, projectId: String, environmentName: String?) throws -> Secret
    func delete(name: String, projectId: String) throws
    func list(projectId: String, environmentName: String?) throws -> [Secret]
    func listInfo(projectId: String) throws -> [SecretInfo]
    func listEnvironments(projectId: String) throws -> [VaultEnvironment]
    func setActiveEnvironment(name: String?, projectId: String) throws
    func importEnv(
        pairs: [(name: String, value: String)],
        projectId: String,
        environmentName: String?,
        overwrite: Bool
    ) throws -> ImportSummary
    func createProjectFromEnv(
        name: String,
        environmentName: String,
        pairs: [(name: String, value: String)],
        overwrite: Bool
    ) throws -> (project: Project, environmentName: String, summary: ImportSummary)
    func setAgentAccess(name: String, projectId: String, policy: AgentAccessPolicy) throws
    func secretCount(projectId: String, environmentName: String?) throws -> Int
    func totalSecretCount(projectId: String) throws -> Int
    func listActivity(limit: Int, filter: ActivityFilter) throws -> [ActivityLogEntry]
    func export(projectId: String, passphrase: String?) throws -> Data
    func exportExcludingApprovalTier(projectId: String, passphrase: String?) throws -> (data: Data, skippedNames: [String])
    func decryptExport(_ envelope: Data, passphrase: String) throws -> [String: String]
    func logAccess(
        secretName: String,
        projectName: String,
        environmentName: String,
        source: ActivityLogEntry.AccessSource,
        agent: String?,
        peerTeamID: String?,
        action: ActivityLogEntry.Action
    )
}

extension Vault: VaultService {}

public enum VaultServiceCapabilityError: Error, LocalizedError {
    case unsupported(String)

    public var errorDescription: String? {
        guard case let .unsupported(operation) = self else { return nil }
        return "Vault service does not support \(operation)."
    }
}

public extension VaultService {
    func addProject(name: String, icon: String?) throws -> Project { throw VaultServiceCapabilityError.unsupported("addProject") }
    func project(id: String) throws -> Project {
        guard let project = try listProjects().first(where: { $0.id == id }) else { throw VaultError.projectNotFound(id) }
        return project
    }
    func project(name: String) throws -> Project? { try listProjects().first { $0.name == name } }
    func deleteProjectIncludingContents(id: String) throws { throw VaultServiceCapabilityError.unsupported("deleteProjectIncludingContents") }
    func activeProjectId() throws -> String? { throw VaultServiceCapabilityError.unsupported("activeProjectId") }
    func setActiveProject(id: String?) throws { throw VaultServiceCapabilityError.unsupported("setActiveProject") }
    func addEnvironment(name: String, projectId: String, color: String?) throws -> VaultEnvironment { throw VaultServiceCapabilityError.unsupported("addEnvironment") }
    func deleteEnvironmentIncludingContents(name: String, projectId: String) throws { throw VaultServiceCapabilityError.unsupported("deleteEnvironmentIncludingContents") }
    func createProjectFromEnv(name: String, environmentName: String, pairs: [(name: String, value: String)], overwrite: Bool) throws -> (project: Project, environmentName: String, summary: ImportSummary) { throw VaultServiceCapabilityError.unsupported("createProjectFromEnv") }
    func setAgentAccess(name: String, projectId: String, policy: AgentAccessPolicy) throws { throw VaultServiceCapabilityError.unsupported("setAgentAccess") }
    func secretCount(projectId: String, environmentName: String?) throws -> Int { throw VaultServiceCapabilityError.unsupported("secretCount") }
    func totalSecretCount(projectId: String) throws -> Int { throw VaultServiceCapabilityError.unsupported("totalSecretCount") }
    func listActivity(limit: Int, filter: ActivityFilter) throws -> [ActivityLogEntry] { throw VaultServiceCapabilityError.unsupported("listActivity") }
    func export(projectId: String, passphrase: String?) throws -> Data { throw VaultServiceCapabilityError.unsupported("export") }
    func exportExcludingApprovalTier(projectId: String, passphrase: String?) throws -> (data: Data, skippedNames: [String]) { throw VaultServiceCapabilityError.unsupported("exportExcludingApprovalTier") }
    func decryptExport(_ envelope: Data, passphrase: String) throws -> [String: String] { throw VaultServiceCapabilityError.unsupported("decryptExport") }
}

/// Serializes access to a wrapped `VaultService` with a single lock held only for
/// the duration of each individual call (M3). The daemon uses this so the vault
/// store — which is not assumed thread-safe — is never touched concurrently,
/// while the *between-call* work in the dispatcher (notably the blocking Touch ID
/// consent prompt for an approval-tier read/write) runs holding no lock. That
/// stops a human deliberating over a prompt from head-of-line-blocking every other
/// client and tripping the daemon's liveness ping. The wrapper never calls back
/// into itself, so a plain non-recursive lock is sufficient.
final class SynchronizedVaultService: VaultService {
    private let base: VaultService
    private let lock = NSLock()

    init(_ base: VaultService) { self.base = base }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    func unlock() throws { try sync { try base.unlock() } }
    func addProject(name: String, icon: String?) throws -> Project {
        try sync { try base.addProject(name: name, icon: icon) }
    }
    func project(id: String) throws -> Project { try sync { try base.project(id: id) } }
    func project(name: String) throws -> Project? { try sync { try base.project(name: name) } }
    func resolveProject(name: String?) throws -> Project {
        try sync { try base.resolveProject(name: name) }
    }
    func listProjects() throws -> [Project] { try sync { try base.listProjects() } }
    func deleteProjectIncludingContents(id: String) throws {
        try sync { try base.deleteProjectIncludingContents(id: id) }
    }
    func activeProjectId() throws -> String? { try sync { try base.activeProjectId() } }
    func setActiveProject(id: String?) throws { try sync { try base.setActiveProject(id: id) } }
    func addEnvironment(name: String, projectId: String, color: String?) throws -> VaultEnvironment {
        try sync { try base.addEnvironment(name: name, projectId: projectId, color: color) }
    }
    func deleteEnvironmentIncludingContents(name: String, projectId: String) throws {
        try sync { try base.deleteEnvironmentIncludingContents(name: name, projectId: projectId) }
    }
    func add(name: String, value: String, description: String?, icon: String?, category: SecretCategory?, projectId: String, environmentName: String?) throws -> Secret {
        try sync { try base.add(name: name, value: value, description: description, icon: icon, category: category, projectId: projectId, environmentName: environmentName) }
    }
    func get(name: String, projectId: String, environmentName: String?) throws -> Secret {
        try sync { try base.get(name: name, projectId: projectId, environmentName: environmentName) }
    }
    func set(name: String, value: String, projectId: String, environmentName: String?) throws -> Secret {
        try sync { try base.set(name: name, value: value, projectId: projectId, environmentName: environmentName) }
    }
    func delete(name: String, projectId: String) throws { try sync { try base.delete(name: name, projectId: projectId) } }
    func list(projectId: String, environmentName: String?) throws -> [Secret] {
        try sync { try base.list(projectId: projectId, environmentName: environmentName) }
    }
    func listInfo(projectId: String) throws -> [SecretInfo] { try sync { try base.listInfo(projectId: projectId) } }
    func listEnvironments(projectId: String) throws -> [VaultEnvironment] { try sync { try base.listEnvironments(projectId: projectId) } }
    func setActiveEnvironment(name: String?, projectId: String) throws { try sync { try base.setActiveEnvironment(name: name, projectId: projectId) } }
    func importEnv(pairs: [(name: String, value: String)], projectId: String, environmentName: String?, overwrite: Bool) throws -> ImportSummary {
        try sync { try base.importEnv(pairs: pairs, projectId: projectId, environmentName: environmentName, overwrite: overwrite) }
    }
    func createProjectFromEnv(name: String, environmentName: String, pairs: [(name: String, value: String)], overwrite: Bool) throws -> (project: Project, environmentName: String, summary: ImportSummary) {
        try sync { try base.createProjectFromEnv(name: name, environmentName: environmentName, pairs: pairs, overwrite: overwrite) }
    }
    func setAgentAccess(name: String, projectId: String, policy: AgentAccessPolicy) throws {
        try sync { try base.setAgentAccess(name: name, projectId: projectId, policy: policy) }
    }
    func secretCount(projectId: String, environmentName: String?) throws -> Int {
        try sync { try base.secretCount(projectId: projectId, environmentName: environmentName) }
    }
    func totalSecretCount(projectId: String) throws -> Int { try sync { try base.totalSecretCount(projectId: projectId) } }
    func listActivity(limit: Int, filter: ActivityFilter) throws -> [ActivityLogEntry] {
        try sync { try base.listActivity(limit: limit, filter: filter) }
    }
    func export(projectId: String, passphrase: String?) throws -> Data {
        try sync { try base.export(projectId: projectId, passphrase: passphrase) }
    }
    func exportExcludingApprovalTier(projectId: String, passphrase: String?) throws -> (data: Data, skippedNames: [String]) {
        try sync { try base.exportExcludingApprovalTier(projectId: projectId, passphrase: passphrase) }
    }
    func decryptExport(_ envelope: Data, passphrase: String) throws -> [String: String] {
        try sync { try base.decryptExport(envelope, passphrase: passphrase) }
    }
    func logAccess(secretName: String, projectName: String, environmentName: String, source: ActivityLogEntry.AccessSource, agent: String?, peerTeamID: String?, action: ActivityLogEntry.Action) {
        sync { base.logAccess(secretName: secretName, projectName: projectName, environmentName: environmentName, source: source, agent: agent, peerTeamID: peerTeamID, action: action) }
    }
}
