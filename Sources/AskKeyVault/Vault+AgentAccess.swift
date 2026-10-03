import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    static var agentAccessPausedConfigKey: String { "agent_access_paused" }

    public func isAgentAccessPaused() throws -> Bool {
        try agentAccessGate.isPaused()
    }

    func synchronizeAgentAccessState() throws {
        let configuredPaused: Bool
        switch try store.configValue(key: Self.agentAccessPausedConfigKey) {
        case nil: configuredPaused = false
        case "true": configuredPaused = true
        default:
            agentAccessGate.invalidate()
            throw VaultError.databaseError("Agent access pause state is invalid.")
        }
        let paused = configuredPaused
        agentAccessGate.synchronize(paused: paused)
        if paused {
            brokerRequests.pauseAndCancelAll()
            approvalRequests.pauseAndCancelAll()
        } else {
            brokerRequests.resume()
            approvalRequests.resume()
        }
    }

    public func pauseAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.pauseReason)
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            try store.setConfigValue(key: Self.agentAccessPausedConfigKey, value: "true")
            brokerRequests.pauseAndCancelAll()
            approvalRequests.pauseAndCancelAll()
            cleanupRuntimeFileDeliveries()
            agentAccessGate.endExclusiveChange(paused: true)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        _ = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            try store.setConfigValue(key: Self.agentAccessPausedConfigKey, value: nil)
            brokerRequests.resume()
            approvalRequests.resume()
            agentAccessGate.endExclusiveChange(paused: false)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    public func cleanupRuntimeFileDeliveries() {
        fileDeliveryManager.cleanupAll()
    }

    public var hasRuntimeFileCleanupFailures: Bool {
        fileDeliveryManager.hasFailures
    }

    /// Resolves the Agent permission without trusting caller-provided identity.
    /// Hidden, unknown, and expired names deliberately share one error.
    public func authorizeAgentCredential(
        named rawName: String,
        operation: AgentCredentialOperation,
        caller: BrokerCallerClaim,
        now: Date = Date()
    ) throws -> AgentCredentialAuthorization {
        try agentAccessGate.beginAgentOperation()
        defer { agentAccessGate.endAgentOperation() }
        _ = caller
        let key = try requireKey()
        guard let displayName = try? CredentialName.displayName(from: rawName) else {
            throw VaultError.credentialUnavailable
        }
        let nameIndex = CredentialIndex.hash(
            normalizedName: CredentialName.normalized(displayName),
            vaultKey: key
        )
        guard let record = try store.fetchCredential(nameIndex: nameIndex),
              let permission = CredentialPermission(rawValue: record.permission),
              permission != .hidden else {
            throw VaultError.credentialUnavailable
        }
        if let expiresAt = try record.expiresAt.map({ try parseExpiry($0) }), expiresAt <= now {
            approvalRequests.cancelPending(credentialID: record.id)
            throw VaultError.credentialUnavailable
        }
        guard operation == .read else { return .requiresApproval }
        return permission == .allowed ? .allowed : .requiresApproval
    }
}
