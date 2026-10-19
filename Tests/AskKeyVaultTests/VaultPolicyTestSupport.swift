import CryptoKit
import Foundation
import AskKeyBroker
@testable import AskKeyVault

extension Vault {
    /// Existing unit fixtures explicitly own a synthetic, authenticated policy.
    /// Security reopen tests use unlock() and bootstrap instead of this adapter.
    convenience init(
        store: VaultStore,
        key: SymmetricKey? = nil,
        now: @escaping () -> Date = Date.init,
        approvalRequests: BrokerApprovalStateMachine = BrokerApprovalStateMachine(),
        fileDeliveryManager: FileDeliveryManager? = nil
    ) {
        let keys = MemoryAppKeyStore(appKey: key.map(VaultCrypto.keyToData))
        keys.policy = key.flatMap { try? AgentAccessPolicyAuthentication.seal(.defaults, using: $0) }
        self.init(store: store, key: key, policyStore: keys, now: now,
                  approvalRequests: approvalRequests, fileDeliveryManager: fileDeliveryManager)
    }
}

final class AgentAccessPolicyLibrary {
    let root: URL
    let paths: VaultBootstrapPaths
    let keys = MemoryAppKeyStore()
    let key = SymmetricKey(data: Data(repeating: 0x51, count: 32))
    let vault: Vault
    let manager: FileDeliveryManager
    var store: VaultStore { get throws { try vault.store } }

    init(open: Bool = true, approvals: BrokerApprovalStateMachine = .init()) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = .init(directory: root.appendingPathComponent("library"))
        manager = try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries"))
        keys.pendingKey = VaultCrypto.keyToData(key)
        vault = Vault(paths: paths, keyStore: keys, approvalRequests: approvals, fileDeliveryManager: manager)
        if open { try vault.unlock() }
    }

    func reopen() throws { try vault.unlock() }

    func close() throws {
        vault.cleanupRuntimeFileDeliveries()
        if let store = try? store { try store.close() }
        try FileManager.default.removeItem(at: root)
    }
}

struct SyntheticPolicyFailure: Error {}
