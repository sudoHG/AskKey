import Foundation

extension Vault {
    /// Only a bound Broker grants writes; every preflight/write checks its identity again.
    package func setAgentAccessPolicyOwnership(
        _ owned: Bool, validateOwnership: @escaping () -> Bool = { true }
    ) throws {
        let paused = try agentAccessGate.beginExclusiveChange()
        defer {
            agentAccessGate.endExclusiveChange(paused: paused,
                                              retryPolicyRead: (try? savedAgentAccessPolicyState().readUnavailable) == true)
        }
        agentAccessPolicyOwnership.set(owned, validate: validateOwnership)
    }

    package func validateAgentAccessPolicyOwnership() throws {
        try agentAccessPolicyOwnership.require()
    }

    func requireAgentAccessPolicyOwnership() throws {
        try agentAccessPolicyOwnership.require()
    }
}
