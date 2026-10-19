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
        catch {
            return .init(policy: .failClosed, needsRecovery: true,
                         keychainConflict: (error as? AppKeyStoreError)?.conflictingItemKind)
        }
        if let value, let policy = try? AgentAccessPolicyAuthentication.open(value, using: key) {
            return .init(policy: policy, needsRecovery: false)
        }
        let latches = agentAccessPolicyLatches()
        if value == nil, created, !latches.pause, !latches.recovery {
            // Only verified first creation may initialize policy, after promotion.
            try keyStore.saveAgentAccessPolicy(AgentAccessPolicyAuthentication.seal(.defaults, using: key))
            return .init(policy: .defaults, needsRecovery: false)
        }
        return .init(policy: .failClosed, needsRecovery: true)
    }

    /// The caller owns the gate's exclusive change for the whole transition.
    func applyAgentAccessPolicy(_ policy: AgentAccessPolicy, needsRecovery: Bool,
                               keychainConflict: AppKeychainItemKind? = nil) {
        if needsRecovery { changeAgentAccessPolicyLatches { $0.recovery = true } }
        let latches = agentAccessPolicyLatches()
        if policy.paused { quiesceAgentAccess() }
        approvalRequests.configureAgentAccessPolicy(
            readAuthenticationEnabled: policy.readApprovalAuthentication,
            timedAllowanceEnabled: policy.timedAllowanceEnabled,
            timedAllowanceDuration: TimeInterval(policy.timedAllowanceMinutes * 60)
        )
        setAgentAccessPolicyState(.init(policy: policy, needsRecovery: needsRecovery || latches.recovery,
                                       pauseNotPersisted: latches.pause && !latches.pausePersisted,
                                       saveFailure: latches.saveFailure, keychainConflict: keychainConflict))
        if !policy.paused {
            brokerRequests.resume()
            approvalRequests.resume()
        }
    }

    /// Reopen cannot undo a process-owned pause or recovery requirement. A
    /// successful retry records persistence without clearing the pause intent.
    func resolveAgentAccessPolicyLatches(
        _ loaded: AgentAccessPolicyState, key: SymmetricKey, keyStore: AppKeyStore
    ) -> AgentAccessPolicyState {
        if loaded.needsRecovery { changeAgentAccessPolicyLatches { $0.recovery = true } }
        let latches = agentAccessPolicyLatches()
        var policy = latches.recovery ? .failClosed : loaded.policy
        if latches.pause {
            policy.paused = true
            if !latches.recovery && !loaded.needsRecovery {
                do {
                    try keyStore.saveAgentAccessPolicy(AgentAccessPolicyAuthentication.seal(policy, using: key))
                    changeAgentAccessPolicyLatches { $0.pausePersisted = true; $0.saveFailure = nil }
                } catch {
                    changeAgentAccessPolicyLatches {
                        $0.pausePersisted = false
                        $0.saveFailure = .init(latches.saveFailure?.operation ?? .pause, cause: error)
                    }
                }
            } else {
                changeAgentAccessPolicyLatches { $0.pausePersisted = false }
            }
        }
        let current = agentAccessPolicyLatches()
        return .init(policy: policy, needsRecovery: current.recovery,
                     pauseNotPersisted: current.pause && !current.pausePersisted,
                     saveFailure: current.saveFailure, keychainConflict: loaded.keychainConflict)
    }

    private func latchUnsavedPause(_ failure: AgentAccessPolicySaveFailure) {
        changeAgentAccessPolicyLatches {
            $0.pause = true; $0.pausePersisted = false; $0.saveFailure = failure
        }
        let state = try? savedAgentAccessPolicyState()
        var policy = state?.policy ?? .failClosed
        policy.paused = true
        applyAgentAccessPolicy(policy, needsRecovery: state?.needsRecovery ?? true,
                               keychainConflict: state?.keychainConflict)
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
            state = try currentAgentAccessPolicy(key: key)
        } catch {
            let failure = AgentAccessPolicySaveFailure(.pause, cause: error)
            latchUnsavedPause(failure)
            throw failure
        }
        var policy = state.policy
        policy.paused = true
        applyAgentAccessPolicy(policy, needsRecovery: state.needsRecovery, keychainConflict: state.keychainConflict)
        if state.needsRecovery { return }
        do {
            try saveAgentAccessPolicy(policy, key: key)
            changeAgentAccessPolicyLatches { if $0.pause { $0.pausePersisted = true; $0.saveFailure = nil } }
            applyAgentAccessPolicy(policy, needsRecovery: false)
        }
        catch {
            let failure = AgentAccessPolicySaveFailure(.pause, cause: error)
            latchUnsavedPause(failure)
            throw failure
        }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var paused = wasPaused
        defer { agentAccessGate.endExclusiveChange(paused: paused) }
        let state = try currentAgentAccessPolicy(key: key)
        paused = state.policy.paused || wasPaused
        applyAgentAccessPolicy(state.policy, needsRecovery: state.needsRecovery, keychainConflict: state.keychainConflict)
        var policy = state.needsRecovery ? .defaults : state.policy
        policy.paused = false
        do {
            try saveAgentAccessPolicy(policy, key: key)
        } catch {
            let failure = AgentAccessPolicySaveFailure(.resume, cause: error)
            latchUnsavedPause(failure)
            paused = true
            throw failure
        }
        changeAgentAccessPolicyLatches { $0 = .init() }
        applyAgentAccessPolicy(policy, needsRecovery: false)
        paused = false
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
        var paused = wasPaused
        var changed = false
        defer { finishCredentialChange(wasPaused: paused, snapshotChanged: changed) }
        let state = try currentAgentAccessPolicy(key: key)
        paused = state.policy.paused || wasPaused
        applyAgentAccessPolicy(state.policy, needsRecovery: state.needsRecovery, keychainConflict: state.keychainConflict)
        guard !state.needsRecovery else { throw AgentAccessPolicyError.recoveryRequired }
        var policy = state.policy
        change(&policy)
        try policy.validate()
        do { try saveAgentAccessPolicy(policy, key: key) }
        catch {
            let failure = AgentAccessPolicySaveFailure(.settings, cause: error)
            latchUnsavedPause(failure)
            paused = true
            throw failure
        }
        applyAgentAccessPolicy(policy, needsRecovery: false)
        paused = policy.paused
        changed = true
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
        try beginAgentOperation()
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
