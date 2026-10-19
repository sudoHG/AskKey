import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

final class AppBoundKeyStoreNativeTests: XCTestCase {
    func testNativeFirstAndRepeatedPolicySavesReopenWithoutAuthenticationUI() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let keys = try fixture.makeStore()
        let paths = VaultBootstrapPaths(directory: fixture.root.appendingPathComponent("library"))
        let vault = Vault(paths: paths, keyStore: keys,
                          fileDeliveryManager: try FileDeliveryManager(rootURL: fixture.root.appendingPathComponent("deliveries")))
        defer { try? vault.store.close() }
        try vault.unlock()
        XCTAssertEqual(try vault.agentAccessPolicyState().policy, .defaults)
        try fixture.assertAppOnlyPolicy()
        try vault.pauseAgentAccess(using: .allow)
        try vault.updateReadApprovalAuthentication(false, using: .allow)
        try vault.updateTimedAllowance(enabled: false, minutes: 120)
        try vault.resumeAgentAccess(using: .allow)
        try vault.unlock()
        let state = try vault.agentAccessPolicyState()
        XCTAssertFalse(state.isPaused)
        XCTAssertFalse(state.policy.readApprovalAuthentication)
        XCTAssertFalse(state.policy.timedAllowanceEnabled)
        XCTAssertEqual(state.policy.timedAllowanceMinutes, 120)
        let reopenedKeys = try fixture.makeStore()
        XCTAssertEqual(try reopenedKeys.loadAgentAccessPolicy(), try keys.loadAgentAccessPolicy())
        try fixture.assertAppOnlyPolicy()
        try reopenedKeys.deleteAgentAccessPolicy()
        XCTAssertNil(try keys.loadAgentAccessPolicy())
        try reopenedKeys.deleteAppKey()
        XCTAssertThrowsError(try keys.loadAppKey())
    }

    func testNativePermissiveItemIsDeletedBeforeAuthenticatedValueIsAdded() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let old = try fixture.addPolicy(Data("unauthenticated".utf8), permissive: true)
        let keys = try fixture.makeStore()
        let key = SymmetricKey(data: Data(repeating: 0x51, count: 32))
        let value = try AgentAccessPolicyAuthentication.seal(.defaults, using: key)
        try keys.saveAgentAccessPolicy(value)
        try fixture.assertOldItemDeleted(old)
        try fixture.assertAppOnlyPolicy()
        XCTAssertEqual(try keys.loadAgentAccessPolicy(), value)
        XCTAssertEqual(try AgentAccessPolicyAuthentication.open(XCTUnwrap(fixture.policyData()), using: key), .defaults)
    }

    func testNativeDeleteFailureDoesNotWriteValidValueOrResume() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let old = Data("unauthenticated-delete-denied".utf8)
        _ = try fixture.addPolicy(old, denyDelete: true)
        let keys = try fixture.makeStore()
        let key = SymmetricKey(data: Data(repeating: 0x51, count: 32))
        let valid = try AgentAccessPolicyAuthentication.seal(.defaults, using: key)
        XCTAssertThrowsError(try keys.saveAgentAccessPolicy(valid)) {
            XCTAssertEqual($0 as? AppKeyStoreError, .policyPersistenceUnknown)
        }
        XCTAssertEqual(try fixture.policyData(), old)
    }

    func testNativeOutsideOnlyPolicyRefusesReadWriteAndDelete() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let old = Data("synthetic-outside".utf8)
        _ = try fixture.addPolicy(old, outside: true, permissive: true)
        let keys = try fixture.makeStore()
        XCTAssertThrowsError(try keys.loadAgentAccessPolicy())
        XCTAssertThrowsError(try keys.saveAgentAccessPolicy(Data("synthetic-new".utf8)))
        XCTAssertThrowsError(try keys.deleteAgentAccessPolicy())
        XCTAssertNil(try fixture.policyData())
        XCTAssertEqual(try fixture.policyData(outside: true), old)
    }

    func testNativeDuplicatePoliciesRefuseReadWriteAndDelete() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let original = Data("synthetic-pinned".utf8)
        _ = try fixture.addPolicy(original)
        _ = try fixture.addPolicy(Data("synthetic-shadow".utf8), outside: true)
        let keys = try fixture.makeStore()
        XCTAssertThrowsError(try keys.loadAgentAccessPolicy())
        XCTAssertThrowsError(try keys.saveAgentAccessPolicy(Data("synthetic-new".utf8)))
        XCTAssertThrowsError(try keys.deleteAgentAccessPolicy())
        XCTAssertEqual(try fixture.policyData(), original)
    }

    func testNativeVaultAndPendingKeyShadowsRefuseReadWriteAndDelete() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let bytes = Data(repeating: 0x42, count: 32)
        let keys = try fixture.makeStore()
        try keys.savePendingKey(bytes)
        try keys.promotePendingKey()
        XCTAssertEqual(try keys.loadAppKey(), bytes)
        XCTAssertEqual(try keys.loadPendingKey(), bytes)
        try fixture.addVaultKey(bytes, suffix: ".pending", outside: true)
        try fixture.addVaultKey(bytes, outside: true)
        try fixture.addVaultKey(bytes, suffix: ".legacy", outside: true)
        XCTAssertThrowsError(try keys.loadAppKey())
        XCTAssertThrowsError(try keys.loadPendingKey())
        XCTAssertThrowsError(try keys.savePendingKey(bytes))
        XCTAssertThrowsError(try keys.promotePendingKey())
        XCTAssertThrowsError(try keys.deleteAppKey())
        XCTAssertThrowsError(try keys.deletePendingKey())
        XCTAssertThrowsError(try keys.deleteLegacyKey())
    }
}
