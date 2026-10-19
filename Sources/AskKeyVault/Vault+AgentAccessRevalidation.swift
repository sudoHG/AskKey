import CryptoKit
import Foundation
import AskKeyBroker

extension Vault {
    /// Caller owns either an authorization condition or an exclusive mutation.
    /// Runtime reads never initialize or repair a missing Keychain policy.
    func currentAgentAccessPolicy(key: SymmetricKey) throws -> AgentAccessPolicyState {
        let memory = try savedAgentAccessPolicyState()
        let persisted = try loadAgentAccessPolicy(key: key, keyStore: policyKeyStore(), created: false)
        let recovery = memory.needsRecovery || persisted.needsRecovery || agentAccessPolicyLatches().recovery
        let policy: AgentAccessPolicy
        if recovery { policy = memory.policy.restricted(by: .failClosed) }
        else if persisted.readUnavailable { policy = memory.policy }
        else { policy = memory.hasVerifiedPolicy ? memory.policy.restricted(by: persisted.policy) : persisted.policy }
        return .init(policy: policy, needsRecovery: recovery,
                     keychainConflict: persisted.keychainConflict ?? memory.keychainConflict,
                     readUnavailable: persisted.readUnavailable,
                     hasVerifiedPolicy: memory.hasVerifiedPolicy || !persisted.readUnavailable)
    }

    func adoptPersistedAgentAccessPolicy(_ state: AgentAccessPolicyState) {
        applyAgentAccessPolicy(state.policy, needsRecovery: state.needsRecovery,
                               keychainConflict: state.keychainConflict, readUnavailable: state.readUnavailable,
                               hasVerifiedPolicy: state.hasVerifiedPolicy,
                               adoptingPersisted: true)
    }

    /// Runs under the gate's condition, before an operation or the actual spawn.
    /// Quiescing here cannot wait for active operations: this may be one of them.
    func revalidateAgentAccessPolicy() throws {
        let previous = try savedAgentAccessPolicyState()
        let current = try currentAgentAccessPolicy(key: requireKey())
        if current.policy != previous.policy || current.needsRecovery != previous.needsRecovery
            || current.readUnavailable != previous.readUnavailable {
            agentAccessGate.setPausedDuringAuthorization(true)
            adoptPersistedAgentAccessPolicy(current)
            agentAccessGate.setPausedDuringAuthorization(current.isPaused,
                                                         retryPolicyRead: current.readUnavailable && !current.policy.paused)
        }
        guard !current.isPaused else { throw VaultError.agentAccessPaused }
    }

    func beginAgentOperation() throws {
        try agentAccessGate.beginAgentOperation(validating: revalidateAgentAccessPolicy)
    }

    /// Agent commits already own the exclusive gate, so retain any newly
    /// discovered pause when the caller's defer releases that gate.
    func revalidateExclusiveAgentAccess(paused: inout Bool) throws {
        let previous = try savedAgentAccessPolicyState()
        let current = try currentAgentAccessPolicy(key: requireKey())
        paused = paused || current.isPaused
        if current.policy != previous.policy || current.needsRecovery != previous.needsRecovery
            || current.readUnavailable != previous.readUnavailable {
            adoptPersistedAgentAccessPolicy(current)
        }
        guard !paused else { throw VaultError.agentAccessPaused }
    }

    /// App decisions pass through the same persisted-policy boundary as requests.
    package func decideAgentApproval(
        requestID: String, capability: String, decision: BrokerApprovalDecision
    ) throws -> BrokerApprovalTicket {
        if decision == .deny {
            return try approvalRequests.decide(requestID: requestID, capability: capability, decision: .deny)
        }
        let policy: AgentAccessPolicy
        do {
            try beginAgentOperation()
            defer { agentAccessGate.endAgentOperation() }
            policy = try savedAgentAccessPolicyState().policy
        }
        let effectiveDecision: BrokerApprovalDecision
        if case let .timedAllow(duration) = decision {
            guard policy.timedAllowanceEnabled else { throw BrokerApprovalError.invalidDecision }
            if let duration, !duration.isFinite || duration <= 0 || duration > 120 * 60 {
                throw BrokerApprovalError.invalidDecision
            }
            effectiveDecision = .timedAllow(duration: min(duration ?? .infinity,
                                                          TimeInterval(policy.timedAllowanceMinutes * 60)))
        } else {
            effectiveDecision = decision
        }
        return try approvalRequests.decide(
            requestID: requestID, capability: capability, decision: effectiveDecision,
            revalidate: {
                try self.agentAccessGate.beginSpawnAuthorization(validating: self.revalidateAgentAccessPolicy)
                defer { self.agentAccessGate.endSpawnAuthorization() }
            }
        )
    }
}
