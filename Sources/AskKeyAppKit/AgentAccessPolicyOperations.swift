import AskKeyVault

struct AgentAccessPolicyOperations {
    var load: () throws -> AgentAccessPolicyState
    var setReadAuthentication: (Bool, ManagementAuthenticator?) throws -> AgentAccessPolicyState
    var setTimedAllowance: (Bool, Int) throws -> AgentAccessPolicyState

    static var live: Self {
        Self(
            load: { try Vault.shared.agentAccessPolicyState() },
            setReadAuthentication: { enabled, authenticator in
                try Vault.shared.updateReadApprovalAuthentication(enabled, using: authenticator)
                return try Vault.shared.agentAccessPolicyState()
            },
            setTimedAllowance: { enabled, minutes in
                try Vault.shared.updateTimedAllowance(enabled: enabled, minutes: minutes)
                return try Vault.shared.agentAccessPolicyState()
            }
        )
    }
}
