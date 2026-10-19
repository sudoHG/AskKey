import CryptoKit
import Foundation
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class AgentAccessPolicyTestLibrary {
    let directory: URL
    let key = SymmetricKey(data: Data(repeating: 0x51, count: 32))
    var store: VaultStore
    var vault: Vault

    init(approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyAppPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        vault = Vault(store: store, key: key, approvalRequests: approvalRequests)
    }

    func reopen() throws {
        try store.close()
        store = try VaultStore(path: directory.appendingPathComponent("vault.db").path)
        vault = Vault(store: store, key: key)
    }

    var operations: AgentAccessPolicyOperations {
        .init(
            load: { try self.vault.agentAccessPolicyState() },
            setReadAuthentication: { enabled, authenticator in
                try self.vault.updateReadApprovalAuthentication(enabled, using: authenticator)
                return try self.vault.agentAccessPolicyState()
            },
            setTimedAllowance: { enabled, minutes in
                try self.vault.updateTimedAllowance(enabled: enabled, minutes: minutes)
                return try self.vault.agentAccessPolicyState()
            }
        )
    }

    func close() throws {
        try store.close()
        try FileManager.default.removeItem(at: directory)
    }
}

/// Isolates ordinary presentation tests from the shared runtime and UserDefaults.
final class AgentAccessPolicyTestState {
    var state = AgentAccessPolicyState(policy: .defaults, needsRecovery: false)

    var operations: AgentAccessPolicyOperations {
        .init(
            load: { self.state },
            setReadAuthentication: { enabled, _ in
                var policy = self.state.policy
                policy.readApprovalAuthentication = enabled
                self.state = .init(policy: policy, needsRecovery: false)
                return self.state
            },
            setTimedAllowance: { enabled, minutes in
                var policy = self.state.policy
                policy.timedAllowanceEnabled = enabled
                policy.timedAllowanceMinutes = minutes
                try policy.validate()
                self.state = .init(policy: policy, needsRecovery: false)
                return self.state
            }
        )
    }
}
