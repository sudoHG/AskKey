import CryptoKit
import Foundation
import GRDB
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessPolicyTests: XCTestCase {
    func testFreshCreationWritesDefaultsOnlyAfterKeyPromotion() throws {
        let library = try makeLibrary()
        XCTAssertNotNil(library.keys.appKey)
        XCTAssertNil(library.keys.pendingKey)
        XCTAssertEqual(library.keys.policyWrites, 1)
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        XCTAssertEqual(try AgentAccessPolicyAuthentication.open(XCTUnwrap(library.keys.policy), using: library.key), .defaults)
        XCTAssertNil(try library.store.configValue(key: Vault.legacyAgentAccessPolicyConfigKey))
        try library.reopen()
        XCTAssertEqual(library.keys.policyWrites, 1)
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, .defaults)
    }

    func testExistingEmptyLibraryNeverInitializesMissingPolicy() throws {
        let library = try makeLibrary()
        library.keys.policy = nil
        try assertFailClosedAfterReopen(library)
    }

    func testRemovingAllRowsCannotUseReopenAsPolicySigner() throws {
        let library = try makeLibrary(withCredential: true)
        let records = try library.store.fetchAllCredentials()
        try library.store.db.write { try $0.execute(sql: "DELETE FROM credentials") }
        library.keys.policy = nil
        try assertFailClosedAfterReopen(library)
        try library.store.db.write { db in
            for record in records { try record.insert(db) }
        }
        try assertFailClosedAfterReopen(library)
        XCTAssertEqual(try library.store.fetchAllCredentials().map(\.id), records.map(\.id))
    }

    func testCrashAfterPromotionBeforePolicySaveStaysFailClosed() throws {
        let library = try makeLibrary(open: false)
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.unlock())
        XCTAssertNotNil(library.keys.appKey)
        XCTAssertNil(library.keys.pendingKey)
        XCTAssertNil(library.keys.policy)
        XCTAssertEqual(library.keys.policyWrites, 0)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        library.keys.policySaveFailure = nil
        try assertFailClosedAfterReopen(library)
    }

    func testBootstrapReportsCreationAndUnfinishedCreationButNotOrdinaryOpen() throws {
        let library = try makeLibrary(open: false)
        let created = try VaultBootstrap.openCurrent(paths: library.paths, keyStore: library.keys)
        XCTAssertTrue(created.created)
        try created.store.close()
        let existing = try VaultBootstrap.openCurrent(paths: library.paths, keyStore: library.keys)
        XCTAssertFalse(existing.created)
        try existing.store.close()
        library.keys.pendingKey = library.keys.appKey
        library.keys.appKey = nil
        let recovered = try VaultBootstrap.openCurrent(paths: library.paths, keyStore: library.keys)
        XCTAssertTrue(recovered.created)
        try recovered.store.close()
    }

    func testDatabasePolicyReplayAndLegacyPauseCannotChangeKeychainPolicy() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        let oldPolicy = try XCTUnwrap(library.keys.policy)
        try library.vault.updateReadApprovalAuthentication(true)
        try library.vault.pauseAgentAccess(using: .allow)
        let currentPolicy = library.keys.policy
        try library.store.setConfigValue(key: Vault.legacyAgentAccessPolicyConfigKey, value: String(decoding: oldPolicy, as: UTF8.self))
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "false")
        try library.reopen()
        let state = try library.vault.agentAccessPolicyState()
        XCTAssertTrue(state.isPaused)
        XCTAssertTrue(state.policy.readApprovalAuthentication)
        XCTAssertFalse(state.needsRecovery)
        XCTAssertEqual(library.keys.policy, currentPolicy)
    }

    func testDeletedPolicyWithActiveOrRecycledCredentialsPausesWithoutWriting() throws {
        for recycled in [false, true] {
            let library = try makeLibrary(withCredential: true)
            if recycled {
                try library.vault.beginManagementSession(using: .allow)
                let credential = try XCTUnwrap(library.vault.listTextCredentials().first)
                try library.vault.deleteTextCredential(id: credential.id, using: .allow)
                XCTAssertTrue(try library.store.fetchAllCredentials().isEmpty)
                XCTAssertFalse(try library.store.fetchRecycledCredentials().isEmpty)
            }
            library.keys.policy = nil
            try assertFailClosedAfterReopen(library)
        }
    }

    func testMalformedOrUnauthenticatedReplacementItemPausesWithoutWriting() throws {
        for value in ["", "not json", "{}", "{\"policy\":null}", "{\"paused\":false}"] {
            let library = try makeLibrary()
            library.keys.policy = Data(value.utf8)
            try assertFailClosedAfterReopen(library)
        }
        let library = try makeLibrary(withCredential: true)
        var value = try envelope(library)
        value["authenticationTag"] = Data(repeating: 0, count: 32).base64EncodedString()
        try setEnvelope(value, in: library)
        try assertFailClosedAfterReopen(library)
    }

    func testEveryChangedPolicyValueWithOldTagPausesWithoutWriting() throws {
        for (field, value) in [
            ("paused", true as Any), ("readApprovalAuthentication", false),
            ("timedAllowanceEnabled", false), ("timedAllowanceMinutes", 120),
        ] {
            let library = try makeLibrary(withCredential: true)
            var valueEnvelope = try envelope(library)
            var policy = try XCTUnwrap(valueEnvelope["policy"] as? [String: Any])
            policy[field] = value
            valueEnvelope["policy"] = policy
            try setEnvelope(valueEnvelope, in: library)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testUnknownVersionAndInvalidMinutesWithValidTagPauseWithoutWriting() throws {
        for change in [["formatVersion": 2]] + [-1, 0, 1, 45, 121, Int.max].map({ ["timedAllowanceMinutes": $0] }) {
            let library = try makeLibrary(withCredential: true)
            try writeSignedPolicy(changing: change, in: library)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testDatabaseDerivationOrDifferentVaultKeyCannotAuthenticatePolicy() throws {
        for info in ["AskKey credential authentication v1", "AskKey agent access policy authentication v1", keychainInfo] {
            let library = try makeLibrary(withCredential: true)
            let key = info == keychainInfo ? SymmetricKey(data: Data(repeating: 0x42, count: 32)) : library.key
            try writeSignedPolicy(changing: [:], in: library, key: key, info: info)
            try assertFailClosedAfterReopen(library)
        }
    }

    func testPolicyLoadFailurePausesWithoutWriting() throws {
        let library = try makeLibrary(withCredential: true)
        library.keys.policyLoadFailure = SyntheticPolicyFailure()
        try assertFailClosedAfterReopen(library)
    }

    func testAuthenticatedRecoveryResumeWritesDefaultsAndSurvivesReopen() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: false, minutes: 120)
        library.keys.policy = nil
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "false")
        try assertFailClosedAfterReopen(library)
        let writes = library.keys.policyWrites
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .deny))
        XCTAssertEqual(library.keys.policyWrites, writes)
        try library.vault.resumeAgentAccess(using: .allow)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        XCTAssertEqual(try library.vault.brokerCredentialCatalog().map(\.name), ["SYNTHETIC"])
    }

    func testOptOutPersistsButDeletedItemRestoresAuthenticationOnSameStateMachine() throws {
        let library = try makeLibrary(withCredential: true)
        let approvals = library.vault.approvalRequests
        approvals.configureAuthentication { _ in false }
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false))
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .deny))
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.reopen()
        XCTAssertTrue(approvals === library.vault.approvalRequests)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.readApprovalAuthentication)
        XCTAssertEqual(try decideRead(approvals).state, .approved)
        library.keys.policy = nil
        try assertFailClosedAfterReopen(library)
        // Exercise the configuration applied by reopen itself: Vault Resume
        // also resets defaults and would mask a stale state-machine opt-out.
        approvals.resume()
        XCTAssertThrowsError(try decideRead(approvals)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(try library.vault.agentAccessPolicyState().needsRecovery)
    }

    func testTimedAllowanceOffIsEnforcedAfterReopenBySameStateMachine() throws {
        let library = try makeLibrary()
        let approvals = library.vault.approvalRequests
        approvals.configureAuthentication { _ in true }
        try library.vault.updateTimedAllowance(enabled: false, minutes: 60)
        try library.reopen()
        let ticket = try approvals.submit(readRequest(), trustedCredentialDeadline: .none)
        XCTAssertThrowsError(try approvals.decide(requestID: ticket.requestID, capability: ticket.capability,
                                                decision: .timedAllow(duration: 60))) {
            XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision)
        }
        XCTAssertEqual(try approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once).state, .approved)
    }

    func testAllowedMinutesPersistAndInvalidMinutesDoNotWrite() throws {
        let library = try makeLibrary()
        for minutes in Vault.allowedTimedAllowanceMinutes {
            try library.vault.updateTimedAllowance(enabled: false, minutes: minutes)
            try library.reopen()
            XCTAssertEqual(try library.vault.agentAccessPolicyState().policy.timedAllowanceMinutes, minutes)
            XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.timedAllowanceEnabled)
        }
        let saved = library.keys.policy
        for minutes in [-1, 0, 45, Int.max] {
            XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: true, minutes: minutes))
            XCTAssertEqual(library.keys.policy, saved)
        }
    }

    func testLegacyPauseAndDeletedPolicyAfterPauseStayFailClosed() throws {
        let library = try makeLibrary(withCredential: true)
        try library.vault.pauseAgentAccess(using: .allow)
        library.keys.policy = nil
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "true")
        try assertFailClosedAfterReopen(library)
    }

    func testFirstSuccessfulPolicySaveDeletesIgnoredLegacyRowsOnce() throws {
        let library = try makeLibrary(open: false)
        let previous = try VaultBootstrap.openCurrent(paths: library.paths, keyStore: library.keys)
        try previous.store.setConfigValue(key: Vault.legacyAgentAccessPolicyConfigKey, value: "untrusted")
        try previous.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "true")
        try previous.store.close()
        try library.reopen()
        XCTAssertTrue(try library.vault.agentAccessPolicyState().needsRecovery)
        XCTAssertEqual(try library.store.configValue(key: Vault.agentAccessPausedConfigKey), "true")
        try library.vault.resumeAgentAccess(using: .allow)
        XCTAssertNil(try library.store.configValue(key: Vault.legacyAgentAccessPolicyConfigKey))
        XCTAssertNil(try library.store.configValue(key: Vault.agentAccessPausedConfigKey))
        try library.store.setConfigValue(key: Vault.agentAccessPausedConfigKey, value: "false")
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertEqual(try library.store.configValue(key: Vault.agentAccessPausedConfigKey), "false")
        try library.reopen()
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
    }

    func testFailClosedReopenRemovesAllowPathDeliveryWithRetainedLease() throws {
        let library = try makeLibrary()
        let (url, lease) = try deliverAllowedFile(library)
        defer { lease?.finish() }
        library.keys.policy = nil
        try assertFailClosedAfterReopen(library)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedPauseSaveStaysPausedCancelsRequestsAndCleansFiles() throws {
        let library = try makeLibrary()
        let (url, lease) = try deliverAllowedFile(library)
        defer { lease?.finish() }
        let ticket = try library.vault.approvalRequests.submit(readRequest(), trustedCredentialDeadline: .none)
        let saved = library.keys.policy
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.pauseAgentAccess(using: .allow)) {
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, .pause)
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.persistedStateIsUnknown, false)
            XCTAssertTrue($0.localizedDescription.contains("may be lost when Ask Key restarts"))
        }
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(try library.vault.agentAccessPolicyState().policy.paused)
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try library.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
    }

    func testFailedSettingsAndResumeSaveKeepSettingsButPauseAccess() throws {
        let library = try makeLibrary(withCredential: true)
        let saved = library.keys.policy
        library.keys.policySaveFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .allow))
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: false, minutes: 120))
        var pausedDefaults = AgentAccessPolicy.defaults
        pausedDefaults.paused = true
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, pausedDefaults)
        XCTAssertTrue(try library.vault.agentAccessPolicyState().pauseNotPersisted)
        XCTAssertEqual(library.keys.policy, saved)
        library.keys.policy = nil
        try library.reopen()
        XCTAssertTrue(try library.vault.agentAccessPolicyState().needsRecovery)
        XCTAssertThrowsError(try library.vault.resumeAgentAccess(using: .allow))
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, .failClosed)
        XCTAssertTrue(try library.vault.agentAccessPolicyState().needsRecovery)
    }

    func testRecoveryRejectsSettingsAndPauseWritesNothing() throws {
        let library = try makeLibrary()
        library.keys.policy = nil
        try assertFailClosedAfterReopen(library)
        let writes = library.keys.policyWrites
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(false, using: .allow))
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(true))
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: true, minutes: 15))
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertNil(library.keys.policy)
    }

    func testLocalEraseDeletesPolicyItemAndVaultKey() throws {
        let library = try makeLibrary()
        try library.vault.beginManagementSession(using: .allow)
        try library.vault.eraseLocalLibrary(confirmation: "ERASE", language: .english, using: .allow)
        XCTAssertNil(library.keys.policy)
        XCTAssertNil(library.keys.appKey)
        XCTAssertEqual(library.keys.policyDeletes, 1)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
    }

    private let keychainInfo = "AskKey keychain agent access policy authentication v1"

    private func makeLibrary(open: Bool = true, withCredential: Bool = false) throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary(open: open)
        addTeardownBlock { try library.close() }
        if withCredential {
            _ = try library.vault.createTextCredential(.init(name: "SYNTHETIC", value: "synthetic-value", permission: .allowed), using: .allow)
        }
        return library
    }

    private func assertFailClosedAfterReopen(_ library: AgentAccessPolicyLibrary) throws {
        let before = try? config(library)
        let saved = library.keys.policy
        let writes = library.keys.policyWrites
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .failClosed, needsRecovery: true))
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        XCTAssertThrowsError(try library.vault.approvalRequests.submit(readRequest(), trustedCredentialDeadline: .none))
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertEqual(library.keys.policyWrites, writes)
        if let before { XCTAssertEqual(try config(library), before) }
    }

    private func config(_ library: AgentAccessPolicyLibrary) throws -> [String: String] {
        try library.store.db.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM config")
                .map { ($0["key"] as String, $0["value"] as String) })
        }
    }

    private func envelope(_ library: AgentAccessPolicyLibrary) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(library.keys.policy)) as? [String: Any])
    }

    private func setEnvelope(_ envelope: [String: Any], in library: AgentAccessPolicyLibrary) throws {
        library.keys.policy = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Signs invalid semantic values independently of the production encoder.
    private func writeSignedPolicy(changing changes: [String: Int], in library: AgentAccessPolicyLibrary,
                                   key: SymmetricKey? = nil, info: String? = nil) throws {
        var value = try envelope(library)
        var policy = try XCTUnwrap(value["policy"] as? [String: Any])
        for (field, change) in changes { policy[field] = change }
        let bytes = try JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys, .withoutEscapingSlashes])
        let macKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: key ?? library.key, salt: Data(),
                                          info: Data((info ?? keychainInfo).utf8), outputByteCount: 32)
        value["policy"] = policy
        value["authenticationTag"] = Data(HMAC<SHA256>.authenticationCode(
            for: Data("AskKey keychain agent access policy v1\0".utf8) + bytes, using: macKey
        )).base64EncodedString()
        try setEnvelope(value, in: library)
    }

    private func readRequest() -> BrokerApprovalOperationRequest {
        .init(operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
              operation: .read, payloadDigest: String(repeating: "a", count: 64))
    }

    private func decideRead(_ approvals: BrokerApprovalStateMachine) throws -> BrokerApprovalTicket {
        let ticket = try approvals.submit(readRequest(), trustedCredentialDeadline: .none)
        return try approvals.decide(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
    }

    private func deliverAllowedFile(_ library: AgentAccessPolicyLibrary) throws -> (URL, BrokerTextDeliveryLease?) {
        let bytes = Data("synthetic-file".utf8)
        _ = try library.vault.createFileCredential(.init(name: "SYNTHETIC_FILE", snapshot: .init(
            originalFilename: "key.pem", bytes: bytes, byteSize: bytes.count, contentDigest: Data()
        ), environmentVariable: "KEY_FILE", permission: .allowed), using: .allow)
        guard case .resolved(let credentials, _, let lease) = try library.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["SYNTHETIC_FILE"]), cancellation: .init()
        ) else { throw SyntheticPolicyFailure() }
        let url = URL(fileURLWithPath: try XCTUnwrap(credentials.first?.value))
        // End the spawn exclusion while retaining the lease that owns the file.
        // Allow deliveries have no approval-runtime authorization to revoke.
        lease?.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return (url, lease)
    }
}
