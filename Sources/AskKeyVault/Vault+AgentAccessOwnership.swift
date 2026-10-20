import Foundation

extension Vault {
    /// Only a bound Broker grants writes; every preflight/write checks its identity again.
    package func setAgentAccessPolicyOwnership(
        _ owned: Bool, validateOwnership: @escaping () -> Bool = { true },
        onRevocation: @escaping @Sendable (Error) -> Void = { _ in }
    ) throws {
        let paused = try agentAccessGate.beginExclusiveChange()
        defer {
            agentAccessGate.endExclusiveChange(paused: paused,
                                              retryPolicyRead: (try? savedAgentAccessPolicyState().readUnavailable) == true)
        }
        agentAccessPolicyOwnership.set(owned, validate: validateOwnership, onRevocation: onRevocation)
        if owned { agentAccessGate.setOwnershipRevoked(false) }
    }

    package func validateAgentAccessPolicyOwnership() throws {
        do { try agentAccessPolicyOwnership.require() }
        catch {
            // A never-owned library may still finish onboarding before its first
            // bind; refusing a request there must not create a revocation pause.
            guard case AgentAccessPolicyError.ownershipRevoked = error else { throw error }
            _ = try agentAccessGate.beginExclusiveChange()
            defer { agentAccessGate.endExclusiveChange(paused: true) }
            pauseForLostAgentAccessOwnership()
            throw error
        }
    }

    /// Policy writes already own the exclusive gate, which is not recursively acquired.
    func requireAgentAccessPolicyOwnership() throws {
        do { try agentAccessPolicyOwnership.require() }
        catch { pauseForLostAgentAccessOwnership(); throw error }
    }

    func pauseForLostAgentAccessOwnership(duringAuthorization: Bool = false) {
        if duringAuthorization { agentAccessGate.setOwnershipRevokedDuringAuthorization(true) }
        else { agentAccessGate.setOwnershipRevoked(true) }
        let state = try? savedAgentAccessPolicyState()
        var policy = state?.policy ?? .defaults
        policy.paused = true
        applyAgentAccessPolicy(policy, needsRecovery: state?.needsRecovery ?? false,
                               keychainConflict: state?.keychainConflict,
                               readUnavailable: state?.readUnavailable ?? false,
                               hasVerifiedPolicy: state?.hasVerifiedPolicy ?? false,
                               readFailure: state?.readFailure)
    }
}
