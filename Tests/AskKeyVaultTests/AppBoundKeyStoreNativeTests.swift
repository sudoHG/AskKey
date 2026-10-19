import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

final class AppBoundKeyStoreNativeTests: XCTestCase {
    func testInitFailureAfterFirstKeychainCreationStillRunsRegisteredCleanup() throws {
        try requireNativeCI()
        let original = try KeychainPreferencesSnapshot()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyNativeInitFailure-\(UUID().uuidString)")
        addTeardownBlock {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                           "Fixture cleanup must run before the pre-registered assertion")
            XCTAssertEqual(try KeychainPreferencesSnapshot(), original,
                           "Failed fixture initialization must restore user Keychain preferences and login contents")
        }

        XCTAssertThrowsError(try KeychainNativeTestSupport(
            test: self,
            temporaryRoot: root,
            afterFirstKeychainCreated: {
                throw NSError(domain: "NativeFixtureInitTest", code: 1)
            }
        )) {
            XCTAssertEqual(($0 as NSError).domain, "NativeFixtureInitTest")
            XCTAssertEqual(($0 as NSError).code, 1)
        }
    }

    func testFixtureCleanupIsIdempotentWithAutomaticTeardown() throws {
        try requireNativeCI()
        let original = try KeychainPreferencesSnapshot()
        let fixture = try KeychainNativeTestSupport(test: self)

        try fixture.cleanup()
        try fixture.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        XCTAssertEqual(try KeychainPreferencesSnapshot(), original)
        // The fixture's automatically registered teardown invokes cleanup a third time.
    }

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
        try fixture.assertOldItemReplaced(old)
        try fixture.assertAppOnlyPolicy()
        XCTAssertEqual(try keys.loadAgentAccessPolicy(), value)
        XCTAssertEqual(try AgentAccessPolicyAuthentication.open(XCTUnwrap(fixture.policyData()), using: key), .defaults)
    }

    func testNativeDeleteFailureDoesNotWriteValidValueOrResume() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let keys = try fixture.makeStore()
        let vault = Vault(paths: .init(directory: fixture.root.appendingPathComponent("library")), keyStore: keys,
                          fileDeliveryManager: try FileDeliveryManager(rootURL: fixture.root.appendingPathComponent("deliveries")))
        defer { try? vault.store.close() }
        try vault.unlock()
        let old = try keys.loadAgentAccessPolicy()
        let before = try fixture.pinnedFileBytes()
        try fixture.makePinnedFileImmutable()
        XCTAssertEqual(try keys.loadAgentAccessPolicy(), old)
        XCTAssertThrowsError(try vault.pauseAgentAccess(using: .allow)) {
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, .pause)
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.persistedStateIsUnknown, true)
        }
        try fixture.assertNativePolicyDeleteFails()
        XCTAssertTrue(try vault.agentAccessPolicyState().isPaused)
        XCTAssertTrue(try vault.agentAccessPolicyState().pauseNotPersisted)
        try vault.unlock()
        XCTAssertTrue(try vault.agentAccessPolicyState().isPaused)
        XCTAssertTrue(try vault.agentAccessPolicyState().pauseNotPersisted)
        XCTAssertThrowsError(try vault.resumeAgentAccess(using: .allow))
        XCTAssertTrue(try vault.agentAccessPolicyState().isPaused)
        XCTAssertEqual(try fixture.pinnedFileBytes(), before)
    }

    func testNativeOutsideOnlyPolicyRefusesReadWriteAndDelete() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let old = Data("synthetic-outside".utf8)
        _ = try fixture.addPolicy(old, outside: true, permissive: true)
        let keys = try fixture.makeStore()
        for operation: () throws -> Void in [
            { _ = try keys.loadAgentAccessPolicy() },
            { try keys.saveAgentAccessPolicy(Data("synthetic-new".utf8)) },
            { try keys.deleteAgentAccessPolicy() },
        ] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? AppKeyStoreError, .conflictingItem(.agentAccessPolicy))
            }
        }
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
        try keys.promotePendingKey(expected: bytes)
        XCTAssertEqual(try keys.loadAppKey(), bytes)
        XCTAssertEqual(try keys.loadPendingKey(), bytes)
        try fixture.addVaultKey(bytes, suffix: ".pending", outside: true)
        try fixture.addVaultKey(bytes, outside: true)
        try fixture.addVaultKey(bytes, suffix: ".legacy", outside: true)
        let operations: [(AppKeychainItemKind, () throws -> Void)] = [
            (.vaultKey, { _ = try keys.loadAppKey() }),
            (.pendingKey, { _ = try keys.loadPendingKey() }),
            (.pendingKey, { try keys.savePendingKey(bytes) }),
            (.pendingKey, { try keys.promotePendingKey(expected: bytes) }),
            (.vaultKey, { try keys.deleteAppKey() }),
            (.pendingKey, { try keys.deletePendingKey() }),
            (.legacyKey, { try keys.deleteLegacyKey() }),
        ]
        for (kind, operation) in operations {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual($0 as? AppKeyStoreError, .conflictingItem(kind))
            }
        }
    }

    func testNativeBootstrapDiscardsPlantedPendingKeyForFreshAndUnfinishedLibraries() throws {
        for current in [false, true] {
            let fixture = try KeychainNativeTestSupport(test: self)
            let keys = try fixture.makeStore()
            let paths = VaultBootstrapPaths(directory: fixture.root.appendingPathComponent("library"))
            if current {
                try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: false)
                let store = try VaultStore(path: paths.currentDatabase.path)
                try store.close()
            }
            let planted = Data(repeating: 0xA7, count: 32)
            try fixture.addVaultKey(planted, suffix: ".pending")
            let opened = try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)
            XCTAssertTrue(opened.created)
            XCTAssertNotEqual(VaultCrypto.keyToData(opened.key), planted)
            XCTAssertEqual(try keys.loadAppKey(), VaultCrypto.keyToData(opened.key))
            XCTAssertThrowsError(try keys.loadPendingKey()) {
                XCTAssertEqual($0 as? AppKeyStoreError, .missingPendingKey)
            }
            try opened.store.close()
        }
    }

    func testNativePromotionRejectsChangedPendingMarkerWithoutWritingAppKey() throws {
        let fixture = try KeychainNativeTestSupport(test: self)
        let keys = try fixture.makeStore()
        let expected = Data(repeating: 0x42, count: 32)
        let planted = Data(repeating: 0xA7, count: 32)
        try keys.savePendingKey(expected)
        try keys.deletePendingKey()
        try fixture.addVaultKey(planted, suffix: ".pending")
        XCTAssertThrowsError(try keys.promotePendingKey(expected: expected)) {
            XCTAssertEqual($0 as? AppKeyStoreError, .conflictingKey)
        }
        XCTAssertThrowsError(try keys.loadAppKey()) {
            XCTAssertEqual($0 as? AppKeyStoreError, .missingAppKey)
        }
        XCTAssertEqual(try keys.loadPendingKey(), planted)
    }

    func testNativeBootstrapPendingConflictPreservesFreshAndUnfinishedLibraries() throws {
        for current in [false, true] {
            for duplicate in [false, true] {
                let fixture = try KeychainNativeTestSupport(test: self)
                let keys = try fixture.makeStore()
                let paths = VaultBootstrapPaths(directory: fixture.root.appendingPathComponent("library"))
                try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: false)
                if current {
                    let store = try VaultStore(path: paths.currentDatabase.path)
                    try store.close()
                }
                let planted = Data(repeating: 0xA7, count: 32)
                if duplicate { try fixture.addVaultKey(planted, suffix: ".pending") }
                try fixture.addVaultKey(planted, suffix: ".pending", outside: true)
                let before = try directoryBytes(paths.directory)
                let keychainBefore = try fixture.pinnedFileBytes()
                XCTAssertThrowsError(try VaultBootstrap.openCurrent(paths: paths, keyStore: keys)) {
                    XCTAssertEqual($0 as? AppKeyStoreError, .conflictingItem(.pendingKey))
                }
                XCTAssertEqual(try directoryBytes(paths.directory), before)
                XCTAssertEqual(try fixture.pinnedFileBytes(), keychainBefore)
                XCTAssertThrowsError(try keys.loadAppKey()) {
                    XCTAssertEqual($0 as? AppKeyStoreError, .missingAppKey)
                }
            }
        }
    }

    private func requireNativeCI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true", environment["GITHUB_ACTIONS"] == "true" else {
            throw XCTSkip("Native Keychain integration runs only in CI.")
        }
    }
}
