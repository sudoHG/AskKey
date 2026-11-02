import CryptoKit
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class TimedAllowanceLockPolicyTests: XCTestCase {
    private let oldBytes = Data(#"{"formatVersion":1,"paused":false,"readApprovalAuthentication":true,"timedAllowanceEnabled":true,"timedAllowanceMinutes":30}"#.utf8)

    func testOlderAuthenticatedPolicyDecodesOffAndReencodesIdenticalBytes() throws {
        let library = try makeLibrary()
        let policy = try JSONDecoder().decode(AgentAccessPolicy.self, from: oldBytes)
        XCTAssertFalse(policy.endTimedAllowancesOnLock)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(try encoder.encode(policy), oldBytes)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: try library.key, salt: Data(),
            info: Data("AskKey keychain agent access policy authentication v1".utf8), outputByteCount: 32)
        let tag = Data(HMAC<SHA256>.authenticationCode(
            for: Data("AskKey keychain agent access policy v1\0".utf8) + oldBytes, using: key))
        library.keys.policy = try JSONSerialization.data(withJSONObject: [
            "policy": JSONSerialization.jsonObject(with: oldBytes), "authenticationTag": tag.base64EncodedString()
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState(), .init(policy: .defaults, needsRecovery: false))
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
    }

    func testMalformedLockPreferenceIsRejectedRatherThanDefaulted() throws {
        for value in [NSNull(), "true", 1, [:]] as [Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
            object["endTimedAllowancesOnLock"] = value
            XCTAssertThrowsError(try JSONDecoder().decode(AgentAccessPolicy.self,
                from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testLockPreferenceIsAuthenticatedAndCannotBeRemovedOrFlipped() throws {
        for replacement in [nil, false] as [Bool?] {
            let library = try makeLibrary()
            try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(library.keys.policy)) as? [String: Any])
            var policy = try XCTUnwrap(envelope["policy"] as? [String: Any])
            policy["endTimedAllowancesOnLock"] = replacement
            envelope["policy"] = policy
            let tampered = try JSONSerialization.data(withJSONObject: envelope)
            XCTAssertThrowsError(try AgentAccessPolicyAuthentication.open(tampered, using: library.key))
        }
    }

    func testBothDirectionsRequireAuthenticationAndPersistOnReopen() throws {
        let library = try makeLibrary()
        for enabled in [true, false] {
            let saved = library.keys.policy
            let writes = library.keys.policyWrites
            XCTAssertThrowsError(try library.vault.updateEndTimedAllowancesOnLock(enabled))
            XCTAssertThrowsError(try library.vault.updateEndTimedAllowancesOnLock(enabled, using: .deny))
            XCTAssertEqual(library.keys.policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            try library.vault.updateEndTimedAllowancesOnLock(enabled, using: .allow)
            try library.reopen()
            XCTAssertEqual(try library.vault.agentAccessPolicyState().policy.endTimedAllowancesOnLock, enabled)
        }
    }

    func testRemoteOptInIsAdoptedWithoutCancellingPendingAndCannotBeSilentlyRelaxed() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        let ticket = try submit(second)
        try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        _ = try second.brokerCredentialCatalog()
        XCTAssertTrue(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
        XCTAssertEqual(try second.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .pending)
        XCTAssertFalse(try second.isAgentAccessPaused())
        try library.vault.updateEndTimedAllowancesOnLock(false, using: .allow)
        _ = try second.brokerCredentialCatalog()
        XCTAssertTrue(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
        try second.updateTimedAllowance(enabled: true, minutes: 15)
        XCTAssertTrue(try AgentAccessPolicyAuthentication.open(XCTUnwrap(library.keys.policy), using: library.key).endTimedAllowancesOnLock)
    }

    func testSessionEndReadsRemoteOptInWithoutCancellingPending() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        second.approvalRequests.configureAuthentication { _ in true }
        let allowed = try submit(second)
        _ = try second.decideAgentApproval(requestID: allowed.requestID, capability: allowed.capability,
                                          decision: .timedAllow(duration: 120))
        let pending = try submit(second, credentialID: "pending")
        try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        // No catalog/authorization boundary refreshed the second process yet.
        XCTAssertFalse(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
        second.updateTimedAllowanceSession(active: false)
        XCTAssertNil(second.approvalRequests.timedAllowanceDeadline(credentialID: "synthetic"))
        XCTAssertEqual(try second.approvalRequests.status(requestID: pending.requestID, capability: pending.capability), .pending)
        XCTAssertFalse(try second.isAgentAccessPaused())
    }

    func testPreparedAllowDeliveryStillSpawnsAfterRemoteOptInAndSessionEnd() throws {
        let library = try makeLibrary()
        try library.vault.beginManagementSession(using: .allow)
        _ = try library.vault.createTextCredential(.init(name: "ALLOW", value: "synthetic", environmentVariable: "TOKEN",
                                                        permission: .allowed), using: .allow)
        let second = try makeSecondVault(library)
        guard case let .resolved(values, _, lease) = try second.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["ALLOW"]), cancellation: .init()) else {
            return XCTFail("Allow must resolve without approval")
        }
        let delivery = try XCTUnwrap(lease)
        defer { delivery.finish(); delivery.cleanup() }
        XCTAssertEqual(values.first?.value, "synthetic")
        try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        second.updateTimedAllowanceSession(active: false)
        var spawned = false
        try delivery.performAuthorizedSpawn(afterAuthorization: {}, spawn: { spawned = true })
        XCTAssertTrue(spawned)
        XCTAssertTrue(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
    }

    func testRemoteOptInAfterRevalidationInvalidatesTimedDecisionBeforeLocalPolicyAdoption() throws {
        for resumeBeforeMutation in [false, true] {
            let library = try makeLibrary()
            let second = try makeSecondVault(library)
            let approvals = second.approvalRequests
            approvals.configureAuthentication { _ in true }
            let timed = try submit(second)
            XCTAssertThrowsError(try approvals.decide(requestID: timed.requestID, capability: timed.capability,
                decision: .timedAllow(duration: 120), revalidate: {
                    try second.agentAccessGate.beginSpawnAuthorization(validating: second.revalidateAgentAccessPolicy)
                    second.agentAccessGate.endSpawnAuthorization()
                    try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
                    XCTAssertFalse(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
                    second.updateTimedAllowanceSession(active: false)
                    // The saved policy is on, but this process still has not
                    // adopted it. Generation equality must be unconditional.
                    XCTAssertFalse(try second.agentAccessPolicyState().policy.endTimedAllowancesOnLock)
                    if resumeBeforeMutation { second.updateTimedAllowanceSession(active: true) }
                })) { XCTAssertEqual($0 as? BrokerApprovalError, .invalidDecision) }
            XCTAssertNil(approvals.timedAllowanceDeadline(credentialID: "synthetic"))
            XCTAssertEqual(try approvals.status(requestID: timed.requestID, capability: timed.capability), .pending)
        }
    }

    func testExistingDeliveryRuleChangesStillRejectPreparedAllowDelivery() throws {
        for change in ["paused", "readApprovalAuthentication", "timedAllowanceEnabled", "timedAllowanceMinutes"] {
            let library = try makeLibrary()
            try library.vault.beginManagementSession(using: .allow)
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            _ = try library.vault.createTextCredential(.init(name: "ALLOW", value: "synthetic", permission: .allowed), using: .allow)
            let second = try makeSecondVault(library)
            guard case let .resolved(_, _, lease) = try second.brokerTextCredentials(
                for: .init(command: ["/usr/bin/true"], credentialNames: ["ALLOW"]), cancellation: .init()) else {
                return XCTFail("Allow must resolve without approval")
            }
            let delivery = try XCTUnwrap(lease)
            defer { delivery.finish(); delivery.cleanup() }
            switch change {
            case "paused": try library.vault.pauseAgentAccess(using: .allow)
            case "readApprovalAuthentication": try library.vault.updateReadApprovalAuthentication(true)
            case "timedAllowanceEnabled": try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
            default: try library.vault.updateTimedAllowance(enabled: true, minutes: 15)
            }
            XCTAssertThrowsError(try delivery.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }), change)
        }
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        return library
    }

    private func makeSecondVault(_ library: AgentAccessPolicyLibrary) throws -> Vault {
        Vault(store: try library.store, key: try library.key, policyStore: library.keys,
              fileDeliveryManager: try FileDeliveryManager(rootURL: library.root.appendingPathComponent("second-deliveries")))
    }

    private func submit(_ vault: Vault, credentialID: String = "synthetic") throws -> BrokerApprovalTicket {
        try vault.approvalRequests.submit(.init(operationID: UUID().uuidString, credentialID: credentialID,
            targetID: credentialID, operation: .read, payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
    }
}
