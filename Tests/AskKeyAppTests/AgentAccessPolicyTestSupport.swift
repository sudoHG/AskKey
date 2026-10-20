import CryptoKit
import Foundation
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

final class AgentAccessPolicyTestLibrary {
    let directory: URL
    let keys = AppPolicyMemoryStore()
    let vault: Vault
    var store: VaultStore { get throws { try vault.store } }

    init(approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyAppPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        vault = Vault(paths: .init(directory: directory.appendingPathComponent("library")), keyStore: keys, approvalRequests: approvalRequests,
                      fileDeliveryManager: try FileDeliveryManager(rootURL: directory.appendingPathComponent("deliveries")))
        try vault.unlock()
    }

    func reopen() throws {
        try vault.unlock()
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
            },
            isPaused: { try self.vault.isAgentAccessPaused() },
            validateOwnership: { try self.vault.validateAgentAccessPolicyOwnership() }
        )
    }

    func close() throws {
        vault.cleanupRuntimeFileDeliveries()
        if let store = try? store { try store.close() }
        try FileManager.default.removeItem(at: directory)
    }
}

final class AppPolicyMemoryStore: AppKeyStore {
    var appKey: Data?
    var pendingKey: Data?
    var policy: Data?
    var saveFailure: Error?
    var loadFailure: Error?
    func savePendingKey(_ data: Data) throws { pendingKey = data }
    func loadPendingKey() throws -> Data {
        guard let pendingKey else { throw AppKeyStoreError.missingPendingKey }
        return pendingKey
    }
    func promotePendingKey(expected data: Data) throws {
        guard try loadPendingKey() == data else { throw AppKeyStoreError.conflictingKey }
        appKey = data
    }
    func loadAppKey() throws -> Data {
        guard let appKey else { throw AppKeyStoreError.missingAppKey }
        return appKey
    }
    func deleteLegacyKey() throws { }
    func deletePendingKey() throws { pendingKey = nil }
    func deleteAppKey() throws { appKey = nil }
    func loadAgentAccessPolicy() throws -> Data? {
        if let loadFailure { throw loadFailure }
        return policy
    }
    func saveAgentAccessPolicy(_ data: Data) throws {
        if let saveFailure { throw saveFailure }
        policy = data
    }
    func deleteAgentAccessPolicy() throws { policy = nil }
}

extension Vault {
    convenience init(
        store: VaultStore,
        key: SymmetricKey? = nil,
        now: @escaping () -> Date = Date.init,
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine(),
        fileDeliveryManager: FileDeliveryManager? = nil
    ) {
        let keys = AppPolicyMemoryStore()
        keys.appKey = key.map(VaultCrypto.keyToData)
        keys.policy = key.flatMap { try? AgentAccessPolicyAuthentication.seal(.defaults, using: $0) }
        self.init(store: store, key: key, policyStore: keys, now: now,
                  approvalRequests: approvalRequests, fileDeliveryManager: fileDeliveryManager)
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
