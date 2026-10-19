import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import AskKeyVault

final class AgentAccessPolicyTests: XCTestCase {
    func testEmptyLibraryWritesAndAppliesDefaultPolicyAfterKeyPromotion() throws {
        let library = try makeLibrary()
        XCTAssertNotNil(library.keys.appKey)
        XCTAssertNil(library.keys.pendingKey)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        let saved = try XCTUnwrap(library.store.configValue(key: Vault.agentAccessPolicyConfigKey))
        XCTAssertEqual(try AgentAccessPolicyAuthentication.open(saved, using: library.key), .defaults)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, .defaults)
    }

    func testDeletedPolicyInNonemptyLibraryPausesWithoutWriting() throws {
        let library = try makeLibrary(withCredential: true)
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
    }

    func testRecycledCredentialsAlsoPreventDefaultInitialization() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.beginManagementSession(using: .allow)
        let credential = try XCTUnwrap(library.vault.listTextCredentials().first)
        try library.vault.deleteTextCredential(id: credential.id, using: .allow)
        XCTAssertTrue(try library.store.fetchAllCredentials().isEmpty)
        XCTAssertFalse(try library.store.fetchRecycledCredentials().isEmpty)
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
    }

    func testTamperedTagPausesWithoutWriting() throws {
        let library = try makeLibrary(withCredential: true)
        var envelope = try envelope(library)
        envelope["authenticationTag"] = Data(repeating: 0, count: 32).base64EncodedString()
        try setEnvelope(envelope, in: library)
        try assertFailClosedAfterReopen(library)
    }

    func testEveryChangedPolicyValueWithOldTagPausesWithoutWriting() throws {
        for (field, value) in [
            ("paused", true as Any), ("readApprovalAuthentication", false),
            ("timedAllowanceEnabled", false), ("timedAllowanceMinutes", 120),
        ] {
            let library = try makeLibrary(withCredential: true)
            var envelope = try envelope(library)
            var policy = try XCTUnwrap(envelope["policy"] as? [String: Any])
            policy[field] = value
            envelope["policy"] = policy
            try setEnvelope(envelope, in: library)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testUnknownVersionWithValidTagPausesWithoutWriting() throws {
        let library = try makeLibrary(withCredential: true)
        try writeSignedPolicy(changing: ["formatVersion": 2], in: library)
        try assertFailClosedAfterReopen(library)
    }

    func testOutOfRangeMinutesWithValidTagPauseWithoutWriting() throws {
        for minutes in [-1, 0, 1, 45, 121, Int.max] {
            let library = try makeLibrary(withCredential: true)
            try writeSignedPolicy(changing: ["timedAllowanceMinutes": minutes], in: library)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testMalformedPolicyPausesWithoutWritingEvenInEmptyLibrary() throws {
        for hasCredential in [false, true] {
            for value in ["", "not json", "{}", "{\"policy\":null}"] {
                let library = try makeLibrary(withCredential: hasCredential)
                try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: value)
                try assertFailClosedAfterReopen(library)
            }
        }
    }

    func testPolicyCannotUseAnotherKeyOrCredentialRecordDerivation() throws {
        for info in ["AskKey credential authentication v1", "AskKey agent access policy authentication v1"] {
            let library = try makeLibrary(withCredential: true)
            let signingKey = info.contains("credential") ? library.key : SymmetricKey(data: Data(repeating: 0x42, count: 32))
            try writeSignedPolicy(changing: [:], in: library, key: signingKey, info: info)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testAuthenticatedResumeFromRecoveryWritesDefaultsAndSurvivesReopen() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: false, minutes: 120)
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "false")
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
        let before = try config(library)
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .deny))
        XCTAssertEqual(try config(library), before)
        try library.vault.resumeAgentAccess(using: .allow)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPausedConfigKey))
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        XCTAssertEqual(try library.vault.brokerCredentialCatalog().map(\.name), ["SYNTHETIC"])
    }

    func testReadAuthenticationOptOutRequiresAuthenticationAndPersists() throws {
        let library = try makeLibrary(withCredential: true)
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false))
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .deny))
        XCTAssertTrue(try library.vault.agentAccessPolicyState().policy.readApprovalAuthentication)
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.reopen()
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.readApprovalAuthentication)
        library.vault.approvalRequests.configureAuthentication { _ in false }
        let ticket = try library.vault.approvalRequests.submit(.init(
            operationID: "read-with-opt-out", credentialID: "synthetic", targetID: "synthetic",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none)
        XCTAssertEqual(try library.vault.approvalRequests.decide(
            requestID: ticket.requestID, capability: ticket.capability, decision: .once
        ).state, .approved)
    }

    func testAllAllowedMinutesAndTimedAllowanceOffPersist() throws {
        let library = try makeLibrary()
        for minutes in Vault.allowedTimedAllowanceMinutes {
            try library.vault.updateTimedAllowance(enabled: false, minutes: minutes)
            try library.reopen()
            let policy = try library.vault.agentAccessPolicyState().policy
            XCTAssertEqual(policy.timedAllowanceMinutes, minutes)
            XCTAssertFalse(policy.timedAllowanceEnabled)
        }
    }

    func testLegacyPauseWithoutPolicyDoesNotResumeAccess() throws {
        let library = try makeLibrary(withCredential: true)
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "true")
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
    }

    func testDeletingOnlyPolicyAfterPauseKeepsAccessPaused() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPausedConfigKey))
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
    }

    func testPausePreservesOtherAuthenticatedSettingsAndRemovesLegacyRow() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: false, minutes: 60)
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "false")
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPausedConfigKey))
        try library.reopen()
        let policy = try library.vault.agentAccessPolicyState().policy
        XCTAssertTrue(policy.paused)
        XCTAssertFalse(policy.readApprovalAuthentication)
        XCTAssertFalse(policy.timedAllowanceEnabled)
        XCTAssertEqual(policy.timedAllowanceMinutes, 60)
        try library.vault.resumeAgentAccess(using: .allow)
        var expected = policy
        expected.paused = false
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, expected)
    }

    func testRecoveryRejectsSettingsAndPauseWritesNothing() throws {
        let library = try makeLibrary(withCredential: true)
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
        let before = try config(library)
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .allow))
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(true))
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: true, minutes: 15))
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertEqual(try config(library), before)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .failClosed, needsRecovery: true))
    }

    func testFailedWritesKeepPolicyGateAndLegacyRowUnchanged() throws {
        let library = try makeLibrary()
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "true")
        let before = try config(library)
        try rejectPolicyWrites(library)
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow))
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .allow))
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: false, minutes: 120))
        XCTAssertEqual(try config(library), before)
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
    }

    func testFailedResumeKeepsRecoveryAndDoesNotWrite() throws {
        let library = try makeLibrary(withCredential: true)
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: nil)
        try assertFailClosedAfterReopen(library)
        let before = try config(library)
        try rejectPolicyWrites(library)
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .allow))
        XCTAssertEqual(try config(library), before)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .failClosed, needsRecovery: true))
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
    }

    private func makeLibrary(withCredential: Bool = false) throws -> PolicyLibrary {
        let library = try PolicyLibrary()
        addTeardownBlock { try library.close() }
        if withCredential {
            _ = try library.vault.createTextCredential(.init(
                name: "SYNTHETIC", value: "synthetic-value", permission: .allowed
            ), using: .allow)
        }
        return library
    }

    private func assertFailClosedAfterReopen(_ library: PolicyLibrary) throws {
        let before = try config(library)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .failClosed, needsRecovery: true))
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog()) { error in
            guard case VaultError.agentAccessPaused = error else { return XCTFail("Expected pause, got \(error)") }
        }
        XCTAssertThrowsError(try library.vault.approvalRequests.submit(.init(
            operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none))
        XCTAssertEqual(try config(library), before, "Recovery must leave saved config untouched")
    }

    private func config(_ library: PolicyLibrary) throws -> [String: String] {
        try library.store.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM config")
                .map { ($0["key"] as String, $0["value"] as String) })
        }
    }

    private func envelope(_ library: PolicyLibrary) throws -> [String: Any] {
        let saved = try XCTUnwrap(library.store.configValue(key: Vault.agentAccessPolicyConfigKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
    }

    private func setEnvelope(_ envelope: [String: Any], in library: PolicyLibrary) throws {
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        try library.store.setConfigValue(key: Vault.agentAccessPolicyConfigKey, value: String(decoding: data, as: UTF8.self))
    }

    /// Deliberately signs invalid semantic values to exercise validation independently of the MAC.
    private func writeSignedPolicy(
        changing changes: [String: Any], in library: PolicyLibrary,
        key: SymmetricKey? = nil, info: String = "AskKey agent access policy authentication v1"
    ) throws {
        var envelope = try envelope(library)
        var policy = try XCTUnwrap(envelope["policy"] as? [String: Any])
        policy.merge(changes) { _, new in new }
        let bytes = Data("AskKey agent access policy v1\0".utf8)
            + (try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys, .withoutEscapingSlashes]))
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key ?? library.key, salt: Data(), info: Data(info.utf8), outputByteCount: 32
        )
        envelope["policy"] = policy
        envelope["authenticationTag"] = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: derived)).base64EncodedString()
        try setEnvelope(envelope, in: library)
    }

    private func rejectPolicyWrites(_ library: PolicyLibrary) throws {
        try library.store.db.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER reject_policy_write BEFORE INSERT ON config
                WHEN NEW.key = 'agent_access_policy'
                BEGIN SELECT RAISE(ABORT, 'synthetic policy write failure'); END
                """)
        }
    }
}

private final class PolicyLibrary {
    let directory: URL
    let keys = MemoryAppKeyStore()
    var store: VaultStore
    var key: SymmetricKey
    var vault: Vault

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyPolicy-\(UUID().uuidString)")
        keys.pendingKey = Data(repeating: 0x51, count: 32)
        let opened = try VaultBootstrap.openCurrent(paths: .init(directory: directory), keyStore: keys)
        store = opened.store
        key = opened.key
        vault = Vault(store: store, key: key)
    }

    func reopen() throws {
        try store.close()
        let opened = try VaultBootstrap.openCurrent(paths: .init(directory: directory), keyStore: keys)
        store = opened.store
        key = opened.key
        vault = Vault(store: store, key: key)
    }

    func close() throws {
        try store.close()
        try FileManager.default.removeItem(at: directory)
    }
}
