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
            let conflict = (error as? AppKeyStoreError)?.conflictingItemKind
            let invalid = conflict != nil || (error as? AppKeyStoreError) == .conflictingKey
            let previous = try? savedAgentAccessPolicyState()
            return .init(policy: invalid ? .failClosed : (previous?.policy ?? .defaults), needsRecovery: invalid,
                         keychainConflict: conflict, readUnavailable: !invalid,
                         hasVerifiedPolicy: previous?.hasVerifiedPolicy ?? false,
                         readFailure: (error as? AppKeyStoreError) == .policyReadAccessDenied ? .accessDenied : .unavailable)
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

    /// The caller owns the gate's exclusive mutation or authorization condition.
    func applyAgentAccessPolicy(_ proposedPolicy: AgentAccessPolicy, needsRecovery: Bool,
                               keychainConflict: AppKeychainItemKind? = nil,
                               readUnavailable: Bool = false, hasVerifiedPolicy: Bool = true,
                               readFailure: AgentAccessPolicyReadFailure? = nil,
                               adoptingPersisted: Bool = false) {
        var policy = proposedPolicy
        if agentAccessPolicyOwnership.isRevoked { policy.paused = true }
        if needsRecovery { changeAgentAccessPolicyLatches { $0.recovery = true } }
        let latches = agentAccessPolicyLatches()
        let previous = try? savedAgentAccessPolicyState()
        let tightened = previous.map { $0.policy.restricted(by: policy) != $0.policy } ?? false
        if policy.paused || readUnavailable || (adoptingPersisted && tightened) { quiesceAgentAccess() }
        approvalRequests.configureAgentAccessPolicy(
            readAuthenticationEnabled: policy.readApprovalAuthentication,
            timedAllowanceEnabled: policy.timedAllowanceEnabled,
            timedAllowanceDuration: TimeInterval(policy.timedAllowanceMinutes * 60)
        )
        let state = AgentAccessPolicyState(policy: policy, needsRecovery: needsRecovery || latches.recovery,
                                          pauseNotPersisted: latches.pause && !latches.pausePersisted,
                                          saveFailure: latches.saveFailure, keychainConflict: keychainConflict,
                                          readUnavailable: readUnavailable, hasVerifiedPolicy: hasVerifiedPolicy,
                                          readFailure: readFailure)
        setAgentAccessPolicyState(state)
        if !state.isPaused {
            brokerRequests.resume()
            approvalRequests.resume()
        }
        if previous != state {
            // A UI observer may read the gate; deliver after this critical section.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .askKeyAgentAccessPolicyDidChange, object: nil)
            }
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
        if latches.saveFailure?.operation == .settings, let memory = try? savedAgentAccessPolicyState() {
            policy = policy.restricted(by: memory.policy)
        }
        if latches.pause {
            policy.paused = true
            if !latches.recovery && !loaded.needsRecovery && !loaded.readUnavailable {
                do {
                    try requireAgentAccessPolicyOwnership()
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
                     saveFailure: current.saveFailure, keychainConflict: loaded.keychainConflict,
                     readUnavailable: loaded.readUnavailable, hasVerifiedPolicy: loaded.hasVerifiedPolicy,
                     readFailure: loaded.readFailure)
    }

    private func latchUnsavedPause(_ failure: AgentAccessPolicySaveFailure) {
        changeAgentAccessPolicyLatches {
            $0.pause = true; $0.pausePersisted = false; $0.saveFailure = failure
        }
        let state = try? savedAgentAccessPolicyState()
        var policy = state?.policy ?? .failClosed
        policy.paused = true
        applyAgentAccessPolicy(policy, needsRecovery: state?.needsRecovery ?? true,
                               keychainConflict: state?.keychainConflict,
                               readUnavailable: state?.readUnavailable ?? false,
                               hasVerifiedPolicy: state?.hasVerifiedPolicy ?? false,
                               readFailure: state?.readFailure)
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
        try requireAgentAccessPolicyOwnership()
        try policyKeyStore().saveAgentAccessPolicy(AgentAccessPolicyAuthentication.seal(policy, using: key))
        if let store = try? store { removeLegacyAgentAccessRows(from: store) }
    }

    public func pauseAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.pauseReason)
        _ = try agentAccessGate.beginExclusiveChange()
        defer { agentAccessGate.endExclusiveChange(paused: true) }
        // Local revocation never depends on a policy read or writing authority.
        quiesceAgentAccess()
        if let state = try? savedAgentAccessPolicyState() {
            var policy = state.policy
            policy.paused = true
            applyAgentAccessPolicy(policy, needsRecovery: state.needsRecovery, keychainConflict: state.keychainConflict,
                                   readUnavailable: state.readUnavailable, hasVerifiedPolicy: state.hasVerifiedPolicy,
                                   readFailure: state.readFailure)
        }
        do { try requireAgentAccessPolicyOwnership() }
        catch {
            latchUnsavedPause(.init(.pause, cause: error))
            return
        }
        let key = try requireKey()
        let state: AgentAccessPolicyState
        do {
            state = try currentAgentAccessPolicy(key: key)
            adoptPersistedAgentAccessPolicy(state)
            guard !state.readUnavailable else { throw state.readFailure ?? .unavailable }
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
            if let ownership = error as? AgentAccessPolicyError, ownership.isOwnershipFailure { return }
            throw failure
        }
    }

    public func resumeAgentAccess(using authenticator: ManagementAuthenticator) throws {
        try validateAgentAccessPolicyOwnership()
        try authorizeManagement(authenticator, reason: CredentialManagementCopy.resumeReason)
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var paused = wasPaused
        defer {
            agentAccessGate.endExclusiveChange(paused: paused,
                                              retryPolicyRead: (try? savedAgentAccessPolicyState().readUnavailable) == true)
        }
        try requireAgentAccessPolicyOwnership()
        let state = try currentAgentAccessPolicy(key: key)
        paused = state.isPaused || wasPaused
        adoptPersistedAgentAccessPolicy(state)
        guard !state.readUnavailable else { throw state.readFailure ?? .unavailable }
        var policy = state.needsRecovery ? .defaults : state.policy
        policy.paused = false
        do {
            try saveAgentAccessPolicy(policy, key: key)
        } catch {
            let failure = AgentAccessPolicySaveFailure(.resume, cause: error)
            latchUnsavedPause(failure)
            paused = true
            if let ownership = error as? AgentAccessPolicyError, ownership.isOwnershipFailure { throw ownership }
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
            try validateAgentAccessPolicyOwnership()
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
        let memory = try savedAgentAccessPolicyState().policy
        var proposed = memory
        change(&proposed)
        if proposed.restricted(by: memory) != proposed { try validateAgentAccessPolicyOwnership() }
        let key = try requireKey()
        let wasPaused = try agentAccessGate.beginExclusiveChange()
        var paused = wasPaused
        var changed = false
        defer { finishCredentialChange(wasPaused: paused, snapshotChanged: changed) }
        let state = try currentAgentAccessPolicy(key: key)
        paused = state.isPaused || wasPaused
        adoptPersistedAgentAccessPolicy(state)
        guard !state.readUnavailable else { throw state.readFailure ?? .unavailable }
        guard !state.needsRecovery else { throw AgentAccessPolicyError.recoveryRequired }
        var policy = state.policy
        change(&policy)
        try policy.validate()
        let tightening = policy.restricted(by: state.policy) == policy
        do { try saveAgentAccessPolicy(policy, key: key) }
        catch {
            let failure = AgentAccessPolicySaveFailure(.settings, cause: error)
            let ownership = error as? AgentAccessPolicyError
            if ownership?.isOwnershipFailure == true, tightening {
                policy.paused = true
                applyAgentAccessPolicy(policy, needsRecovery: state.needsRecovery)
            }
            latchUnsavedPause(failure)
            paused = true
            if let ownership, ownership.isOwnershipFailure, !tightening { throw ownership }
            throw failure
        }
        applyAgentAccessPolicy(policy, needsRecovery: false)
        paused = wasPaused || policy.paused
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
