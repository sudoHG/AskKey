import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    static var agentAccessPausedConfigKey: String { "agent_access_paused" }
    static var legacyAgentAccessPolicyConfigKey: String { "agent_access_policy" }
    package static let allowedTimedAllowanceMinutes = [15, 30, 60, 120]

    public func isAgentAccessPaused() throws -> Bool {
        try agentAccessGate.isPaused()
    }

    func loadAgentAccessPolicy(
        key: SymmetricKey, keyStore: AppKeyStore, created: Bool
    ) throws -> AgentAccessPolicyState {
        let value: Data?
        do { value = try keyStore.loadAgentAccessPolicy() }
        catch { return .init(policy: .failClosed, needsRecovery: true) }
        if let value, let policy = try? AgentAccessPolicyAuthentication.open(value, using: key) {
            return .init(policy: policy, needsRecovery: false)
        }
        if value == nil, created {
            // Only verified first creation may initialize policy, after promotion.
            try keyStore.saveAgentAccessPolicy(AgentAccessPolicyAuthentication.seal(.defaults, using: key))
            return .init(policy: .defaults, needsRecovery: false)
        }
        return .init(policy: .failClosed, needsRecovery: true)
    }

    /// The caller owns the gate's exclusive change for the whole transition.
    func applyAgentAccessPolicy(_ policy: AgentAccessPolicy, needsRecovery: Bool) {
        if policy.paused { quiesceAgentAccess() }
        approvalRequests.configureAgentAccessPolicy(
            readAuthenticationEnabled: policy.readApprovalAuthentication,
            timedAllowanceEnabled: policy.timedAllowanceEnabled,
            timedAllowanceDuration: TimeInterval(policy.timedAllowanceMinutes * 60)
        )
        setAgentAccessPolicyState(.init(policy: policy, needsRecovery: needsRecovery))
        if !policy.paused {
            brokerRequests.resume()
            approvalRequests.resume()
        }
    }

    /// Pause the gate before calling: cancellation callbacks and file removal
    /// must not race a new authorization or delivery.
    func quiesceAgentAccess() {
        brokerRequests.pauseAndCancelAll()
        approvalRequests.pauseAndCancelAll()
        cleanupRuntimeFileDeliveries()
    }

    func removeLegacyAgentAccessRows(from store: VaultStore) {
        guard !legacyAgentAccessRowsRemoved else { return }
        // These ignored rows never control policy, including if cleanup fails.
        do {
            try store.removeLegacyAgentAccessConfig()
            legacyAgentAccessRowsRemoved = true
        } catch { }
    }

    private func saveAgentAccessPolicy(_ policy: AgentAccessPolicy, key: SymmetricKey) throws {
        try policyKeyStore().saveAgentAccessPolicy(AgentAccessPolicyAuthentication.seal(policy, using: key))
        if let store = try? store { removeLegacyAgentAccessRows(from: store) }
    }

    public func pauseAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.pauseReason)
        let key = try requireKey()
        _ = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: true) }
        let state: AgentAccessPolicyState
        do {
            state = try savedAgentAccessPolicyState()
        } catch {
            quiesceAgentAccess()
            setAgentAccessPolicyState(.init(policy: .failClosed, needsRecovery: true))
            throw AgentAccessPolicyError.pauseNotSaved
        }
        var policy = state.policy
        policy.paused = true
        applyAgentAccessPolicy(policy, needsRecovery: state.needsRecovery)
        if state.needsRecovery { return }
        do { try saveAgentAccessPolicy(policy, key: key) }
        catch { throw AgentAccessPolicyError.pauseNotSaved }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        do {
            let state = try savedAgentAccessPolicyState()
            var policy = state.needsRecovery ? .defaults : state.policy
            policy.paused = false
            try saveAgentAccessPolicy(policy, key: key)
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

    private func changeAgentAccessPolicy(_ change: (inout AgentAccessPolicy) -> Void) throws {
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: wasPaused) }
        let state = try savedAgentAccessPolicyState()
        guard !state.needsRecovery else { throw AgentAccessPolicyError.recoveryRequired }
        var policy = state.policy
        change(&policy)
        try saveAgentAccessPolicy(policy, key: key)
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
