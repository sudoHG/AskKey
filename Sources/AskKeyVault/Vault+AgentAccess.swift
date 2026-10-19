import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    static var agentAccessPausedConfigKey: String { "agent_access_paused" }
    static var agentAccessPolicyConfigKey: String { "agent_access_policy" }
    package static let allowedTimedAllowanceMinutes = [15, 30, 60, 120]

    public func isAgentAccessPaused() throws -> Bool {
        try agentAccessGate.isPaused()
    }

    func synchronizeAgentAccessState() throws {
        let key = try requireKey()
        let inputs = try store.agentAccessPolicyInputs()
        let policy: AgentAccessPolicy
        let needsRecovery: Bool
        if let value = inputs.value,
           let verified = try? AgentAccessPolicyAuthentication.open(value, using: key) {
            policy = verified
            needsRecovery = false
        } else if inputs.value == nil, !inputs.hasCredentials {
            // Bootstrap has already promoted the App key before this write.
            policy = .defaults
            try store.writeAgentAccessPolicy(policy, using: key)
            needsRecovery = false
        } else {
            policy = .failClosed
            needsRecovery = true
        }
        applyAgentAccessPolicy(policy, needsRecovery: needsRecovery)
        agentAccessGate.synchronize(paused: policy.paused)
    }

    private func applyAgentAccessPolicy(_ policy: AgentAccessPolicy, needsRecovery: Bool) {
        approvalRequests.setReadAuthenticationEnabled(policy.readApprovalAuthentication)
        approvalRequests.updateDefaultTimedAllowance(TimeInterval(policy.timedAllowanceMinutes * 60))
        setAgentAccessPolicyState(.init(policy: policy, needsRecovery: needsRecovery))
        if policy.paused {
            brokerRequests.pauseAndCancelAll()
            approvalRequests.pauseAndCancelAll()
        } else {
            brokerRequests.resume()
            approvalRequests.resume()
        }
    }

    public func pauseAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.pauseReason)
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            let state = try agentAccessPolicyState()
            if state.needsRecovery {
                agentAccessGate.endExclusiveChange(paused: true)
                return
            }
            var policy = state.policy
            policy.paused = true
            try store.writeAgentAccessPolicy(policy, using: key)
            applyAgentAccessPolicy(policy, needsRecovery: false)
            cleanupRuntimeFileDeliveries()
            agentAccessGate.endExclusiveChange(paused: true)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            let state = try agentAccessPolicyState()
            var policy = state.needsRecovery ? .defaults : state.policy
            policy.paused = false
            try store.writeAgentAccessPolicy(policy, using: key)
            applyAgentAccessPolicy(policy, needsRecovery: false)
            agentAccessGate.endExclusiveChange(paused: false)
        } catch {
            agentAccessGate.endExclusiveChange(paused: wasPaused)
            throw error
        }
    }

    package func updateReadApprovalAuthentication(
        _ enabled: Bool, using authenticator: ManagementAuthenticator? = nil
    ) throws {
        if !enabled {
            guard let authenticator else { throw VaultError.managementAuthenticationRequired }
            try authorizeManagement(authenticator, reason: "Disable system authentication for read approvals")
        }
        try changeAgentAccessPolicy { $0.readApprovalAuthentication = enabled }
    }

    package func updateTimedAllowance(enabled: Bool, minutes: Int) throws {
        try changeAgentAccessPolicy {
            $0.timedAllowanceEnabled = enabled
            $0.timedAllowanceMinutes = minutes
        }
    }

    public func updateDefaultTimedAllowanceMinutes(_ minutes: Int) throws {
        try changeAgentAccessPolicy { $0.timedAllowanceMinutes = minutes }
    }

    private func changeAgentAccessPolicy(_ change: (inout AgentAccessPolicy) -> Void) throws {
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let state = try agentAccessPolicyState()
        guard !state.needsRecovery else { throw AgentAccessPolicyError.recoveryRequired }
        var policy = state.policy
        change(&policy)
        try store.writeAgentAccessPolicy(policy, using: key)
        applyAgentAccessPolicy(policy, needsRecovery: false)
        notifySnapshotRelevantChange()
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
