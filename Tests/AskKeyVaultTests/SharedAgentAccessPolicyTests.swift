import CryptoKit
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class SharedAgentAccessPolicyTests: XCTestCase {
    func testRemotePauseRejectsFinalSpawnAndCleansMaterializedFile() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        let lease = try resolvedLease(second)
        try library.vault.pauseAgentAccess(using: .allow)
        var spawned = false
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { spawned = true }))
        XCTAssertFalse(spawned)
        XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
        XCTAssertTrue(try second.agentAccessPolicyState().policy.paused)
        XCTAssertTrue(try deliveryFiles(library).isEmpty)
        lease.finish()
        lease.cleanup()
    }

    func testRemotePauseIsAdoptedByCatalogGroupsAndApprovalDecision() throws {
        for boundary in ["catalog", "groups", "decision"] {
            let library = try makeLibrary()
            let second = try makeSecondVault(library)
            let ticket = try submitRead(second)
            let delivery = try second.fileDeliveryManager.get().materialize(
                credentialID: "synthetic", bytes: Data("synthetic".utf8)
            )
            try library.vault.pauseAgentAccess(using: .allow)
            switch boundary {
            case "catalog": XCTAssertThrowsError(try second.brokerCredentialCatalog())
            case "groups": XCTAssertThrowsError(try second.brokerCredentialGroups())
            default: XCTAssertThrowsError(try decide(second, ticket: ticket))
            }
            XCTAssertTrue(try second.agentAccessPolicyState().isPaused, boundary)
            XCTAssertTrue(try second.agentAccessPolicyState().policy.paused, boundary)
            XCTAssertEqual(try second.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
        }
    }

    func testStricterPolicyRejectsAllowedDeliveryEvenIfCatalogAlreadyAdoptedIt() throws {
        for adoptFirst in [false, true] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            let second = try makeSecondVault(library)
            let lease = try resolvedLease(second)
            defer { lease.finish(); lease.cleanup() }
            try library.vault.updateReadApprovalAuthentication(true)
            if adoptFirst { _ = try second.brokerCredentialCatalog() }
            XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
            XCTAssertTrue(try deliveryFiles(library).isEmpty)
            XCTAssertTrue(try second.agentAccessPolicyState().policy.readApprovalAuthentication)
        }
    }

    func testStaleSettingsSaveKeepsPersistedPauseAndStricterSettings() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
        let second = try makeSecondVault(library)
        try library.vault.updateReadApprovalAuthentication(true)
        try library.vault.updateTimedAllowance(enabled: false, minutes: 15)
        try library.vault.pauseAgentAccess(using: .allow)
        try second.updateReadApprovalAuthentication(true)
        let persisted = try persistedPolicy(library)
        XCTAssertTrue(persisted.paused)
        XCTAssertTrue(persisted.readApprovalAuthentication)
        XCTAssertFalse(persisted.timedAllowanceEnabled)
        XCTAssertEqual(persisted.timedAllowanceMinutes, 15)
        XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
        XCTAssertThrowsError(try second.brokerCredentialCatalog())
    }

    func testPauseAndResumePreserveNewerPersistedSettings() throws {
        for resume in [false, true] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
            let second = try makeSecondVault(library)
            try library.vault.updateReadApprovalAuthentication(true)
            try library.vault.updateTimedAllowance(enabled: false, minutes: 15)
            if resume { try second.resumeAgentAccess(using: .allow) }
            else { try second.pauseAgentAccess(using: .allow) }
            let persisted = try persistedPolicy(library)
            XCTAssertEqual(persisted.paused, !resume)
            XCTAssertTrue(persisted.readApprovalAuthentication)
            XCTAssertFalse(persisted.timedAllowanceEnabled)
            XCTAssertEqual(persisted.timedAllowanceMinutes, 15)
        }
    }

    func testSettingsSaveAndResumeQuiesceWhenAdoptingStricterPersistedPolicy() throws {
        for resume in [false, true] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            let second = try makeSecondVault(library)
            let ticket = try submitRead(second)
            _ = try decide(second, ticket: ticket)
            let delivery = try second.fileDeliveryManager.get().materialize(
                credentialID: "synthetic", bytes: Data("synthetic".utf8)
            )
            try library.vault.updateReadApprovalAuthentication(true)
            if resume { try second.resumeAgentAccess(using: .allow) }
            else { try second.updateTimedAllowance(enabled: true, minutes: 30) }
            XCTAssertEqual(try second.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
            XCTAssertTrue(try second.agentAccessPolicyState().policy.readApprovalAuthentication)
            XCTAssertFalse(try second.isAgentAccessPaused())
        }
    }

    func testRemoteAuthenticationOptInCancelsOldApprovalsAndRequiresAuthentication() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        let second = try makeSecondVault(library)
        second.approvalRequests.configureAuthentication { _ in false }
        let old = try submitRead(second)
        try library.vault.updateReadApprovalAuthentication(true)
        XCTAssertThrowsError(try decide(second, ticket: old))
        XCTAssertTrue(try second.agentAccessPolicyState().policy.readApprovalAuthentication)
        let fresh = try submitRead(second)
        XCTAssertThrowsError(try decide(second, ticket: fresh)) {
            XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed)
        }
        XCTAssertEqual(try second.approvalRequests.status(requestID: fresh.requestID, capability: fresh.capability), .pending)
    }

    func testRemoteTimedAllowanceDisableRevokesConsumedRuntimeAuthorization() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["ASK"])
        guard case let .approvalRequired(tickets) = try second.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected an Ask approval")
        }
        let ticket = try XCTUnwrap(tickets.first)
        _ = try decide(second, ticket: ticket, decision: .timedAllow(duration: 120))
        guard case let .resolved(_, _, lease) = try second.brokerTextCredentials(for: request, cancellation: .init()) else {
            return XCTFail("Expected a resolved lease")
        }
        let delivery = try XCTUnwrap(lease)
        defer { delivery.finish(); delivery.cleanup() }
        try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
        XCTAssertThrowsError(try delivery.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
        XCTAssertFalse(try second.agentAccessPolicyState().policy.timedAllowanceEnabled)
        XCTAssertNil(second.approvalRequests.timedAllowanceDeadline(credentialID: try askCredentialID(library)))
        let fresh = try submitRead(second)
        XCTAssertThrowsError(try decide(second, ticket: fresh, decision: .timedAllow(duration: 120)))
    }

    func testSmallerPersistedDurationCapsApprovalFromStaleUI() throws {
        let library = try makeLibrary()
        try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
        let second = try makeSecondVault(library)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 15)
        _ = try second.brokerCredentialCatalog()
        let ticket = try submitRead(second)
        let before = Date()
        _ = try decide(second, ticket: ticket, decision: .timedAllow(duration: 120 * 60))
        let deadline = try XCTUnwrap(second.approvalRequests.timedAllowanceDeadline(credentialID: "synthetic"))
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(before), 15 * 60 + 1)
        XCTAssertEqual(try second.agentAccessPolicyState().policy.timedAllowanceMinutes, 15)
    }

    func testRemotePauseRejectsApprovedAgentCommitAndRetainsPausedGate() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        let request = AgentTextWriteRequest(operationID: UUID().uuidString, action: .create(name: "NEW", value: "synthetic"))
        guard case let .submitted(submission) = try second.requestAgentTextWrite(request) else {
            return XCTFail("Expected a pending write")
        }
        _ = try second.decideAgentApproval(requestID: submission.requestID, capability: submission.capability, decision: .once)
        try library.vault.pauseAgentAccess(using: .allow)
        XCTAssertThrowsError(try second.commitAgentTextWrite(request, requestID: submission.requestID, capability: submission.capability))
        XCTAssertTrue(try second.agentAccessPolicyState().policy.paused)
        XCTAssertTrue(try second.isAgentAccessPaused())
        XCTAssertEqual(try second.approvalRequests.status(requestID: submission.requestID, capability: submission.capability), .cancelled)
        XCTAssertEqual(try library.store.fetchAllCredentials().count, 2)
    }

    func testConfirmedMissingInvalidAndConflictingPolicyRequireRecoveryAtEveryBoundary() throws {
        for corruption in ["missing", "invalid", "conflict", "wrong-key"] {
            for boundary in ["spawn", "catalog", "groups", "decision"] {
                let library = try makeLibrary()
                let second = try makeSecondVault(library)
                let ticket = try submitRead(second)
                let lease = boundary == "spawn" ? try resolvedLease(second) : nil
                defer { lease?.finish(); lease?.cleanup() }
                switch corruption {
                case "missing": library.keys.policy = nil
                case "invalid": library.keys.policy = Data("invalid".utf8)
                case "conflict": library.keys.policyLoadFailure = AppKeyStoreError.conflictingItem(.agentAccessPolicy)
                default:
                    library.keys.policy = try AgentAccessPolicyAuthentication.seal(
                        .defaults, using: SymmetricKey(data: Data(repeating: 0x23, count: 32))
                    )
                }
                let writes = library.keys.policyWrites
                switch boundary {
                case "spawn":
                    XCTAssertThrowsError(try lease?.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
                case "catalog": XCTAssertThrowsError(try second.brokerCredentialCatalog())
                case "groups": XCTAssertThrowsError(try second.brokerCredentialGroups())
                default: XCTAssertThrowsError(try decide(second, ticket: ticket))
                }
                let state = try second.agentAccessPolicyState()
                XCTAssertTrue(state.isPaused, "\(corruption), \(boundary)")
                XCTAssertTrue(state.needsRecovery)
                XCTAssertTrue(state.policy.readApprovalAuthentication)
                XCTAssertFalse(state.policy.timedAllowanceEnabled)
                XCTAssertEqual(library.keys.policyWrites, writes)
            }
        }
    }

    func testUnreadablePolicyRefusesEveryBoundaryAndRecoversWithoutResettingSettings() throws {
        for boundary in ["spawn", "catalog", "groups", "decision"] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
            let second = try makeSecondVault(library)
            let ticket = try submitRead(second)
            let lease = boundary == "spawn" ? try resolvedLease(second) : nil
            defer { lease?.finish(); lease?.cleanup() }
            let saved = try persistedPolicy(library)
            let writes = library.keys.policyWrites
            library.keys.policyLoadFailure = SyntheticPolicyFailure()
            switch boundary {
            case "spawn":
                XCTAssertThrowsError(try lease?.performAuthorizedSpawn(afterAuthorization: {}, spawn: { XCTFail("Must not spawn") }))
            case "catalog": XCTAssertThrowsError(try second.brokerCredentialCatalog())
            case "groups": XCTAssertThrowsError(try second.brokerCredentialGroups())
            default: XCTAssertThrowsError(try decide(second, ticket: ticket))
            }
            XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
            XCTAssertFalse(try second.agentAccessPolicyState().needsRecovery)
            XCTAssertEqual(try second.agentAccessPolicyState().policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            // Drop any delivery lease before taking the exclusive Resume gate.
            lease?.finish()
            library.keys.policyLoadFailure = nil
            if boundary == "decision" { try second.resumeAgentAccess(using: .allow) }
            else { _ = try second.brokerCredentialCatalog() }
            XCTAssertFalse(try second.agentAccessPolicyState().isPaused)
            XCTAssertFalse(try second.agentAccessPolicyState().needsRecovery)
            XCTAssertEqual(try second.agentAccessPolicyState().policy, saved)
            XCTAssertEqual(try persistedPolicy(library), saved)
        }
    }

    func testPauseDuringUnreadablePolicyLatchesUnsavedPauseWithoutRecovery() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        let saved = library.keys.policy
        library.keys.policyLoadFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try second.pauseAgentAccess(using: .allow)) {
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, .pause)
        }
        let state = try second.agentAccessPolicyState()
        XCTAssertTrue(state.isPaused)
        XCTAssertTrue(state.pauseNotPersisted)
        XCTAssertFalse(state.needsRecovery)
        XCTAssertEqual(state.saveFailure?.operation, .pause)
        XCTAssertEqual(library.keys.policy, saved)
        library.keys.policyLoadFailure = nil
        XCTAssertThrowsError(try second.brokerCredentialCatalog())
        try second.resumeAgentAccess(using: .allow)
        XCTAssertFalse(try second.agentAccessPolicyState().isPaused)
    }

    func testInitialUnreadablePolicyRecoversTheVerifiedSettingsWithoutUsingDefaults() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
        let saved = try persistedPolicy(library)
        library.keys.policyLoadFailure = SyntheticPolicyFailure()
        let second = try makeSecondVault(library)
        XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
        XCTAssertFalse(try second.agentAccessPolicyState().needsRecovery)
        library.keys.policyLoadFailure = nil
        _ = try second.brokerCredentialCatalog()
        XCTAssertFalse(try second.agentAccessPolicyState().isPaused)
        XCTAssertEqual(try second.agentAccessPolicyState().policy, saved)
    }

    func testSettingsAndResumeRefuseUnreadablePolicyAndRetryWithoutWritingDefaults() throws {
        for resume in [false, true] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
            let saved = try persistedPolicy(library)
            let writes = library.keys.policyWrites
            library.keys.policyLoadFailure = SyntheticPolicyFailure()
            XCTAssertThrowsError(try {
                if resume { try library.vault.resumeAgentAccess(using: .allow) }
                else { try library.vault.updateTimedAllowance(enabled: false, minutes: 15) }
            }())
            XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
            XCTAssertFalse(try library.vault.agentAccessPolicyState().needsRecovery)
            XCTAssertEqual(library.keys.policyWrites, writes)
            library.keys.policyLoadFailure = nil
            _ = try library.vault.brokerCredentialCatalog()
            XCTAssertFalse(try library.vault.agentAccessPolicyState().isPaused)
            XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, saved)
            XCTAssertEqual(try persistedPolicy(library), saved)
        }
    }

    func testNonOwnerCannotSaveSettingsPauseOrResumeOverOwnersPolicy() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        try second.setAgentAccessPolicyOwnership(false)
        try library.vault.pauseAgentAccess(using: .allow)
        let saved = library.keys.policy
        let writes = library.keys.policyWrites
        library.keys.onPolicyLoad = { XCTFail("A non-owner must refuse before reading for a write") }
        for operation in [
            { try second.updateTimedAllowance(enabled: false, minutes: 15) },
            { try second.updateReadApprovalAuthentication(false, using: .allow) },
            { try second.pauseAgentAccess(using: .allow) },
            { try second.resumeAgentAccess(using: .allow) }
        ] {
            XCTAssertThrowsError(try operation()) {
                XCTAssertEqual(($0 as? AgentAccessPolicyError)?.errorDescription,
                               AgentAccessPolicyError.notOwner.errorDescription)
            }
        }
        library.keys.onPolicyLoad = nil
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertThrowsError(try second.brokerCredentialCatalog())
        XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
    }

    func testWeakerPersistedPolicyCannotRelaxMemoryOrRecoveryLatch() throws {
        let library = try makeLibrary()
        let second = try makeSecondVault(library)
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
        _ = try second.brokerCredentialCatalog()
        XCTAssertTrue(try second.agentAccessPolicyState().policy.readApprovalAuthentication)
        XCTAssertEqual(try second.agentAccessPolicyState().policy.timedAllowanceMinutes, 30)
        library.keys.policy = nil
        XCTAssertThrowsError(try second.brokerCredentialCatalog())
        library.keys.policy = try AgentAccessPolicyAuthentication.seal(.defaults, using: library.key)
        XCTAssertThrowsError(try second.brokerCredentialCatalog())
        XCTAssertTrue(try second.agentAccessPolicyState().needsRecovery)
        try second.resumeAgentAccess(using: .allow)
        XCTAssertFalse(try second.agentAccessPolicyState().isPaused)
    }

    func testRemotePolicyChangeDuringSystemAuthenticationRefusesDecision() throws {
        for change in ["pause", "read-authentication", "timed-allowance", "missing"] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            let second = try makeSecondVault(library)
            let ticket = try second.approvalRequests.submit(.init(
                operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
                operation: .modify, payloadDigest: String(repeating: "b", count: 64)
            ), trustedCredentialDeadline: .none)
            let action = AuthenticationPolicyChange(library: library, change: change)
            second.approvalRequests.configureAuthentication { _ in action.apply(); return true }
            XCTAssertThrowsError(try decide(second, ticket: ticket))
            XCTAssertNil(action.failure)
            XCTAssertEqual(try second.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
            if change == "pause" || change == "missing" {
                XCTAssertTrue(try second.agentAccessPolicyState().isPaused)
            }
            if change == "read-authentication" {
                XCTAssertTrue(try second.agentAccessPolicyState().policy.readApprovalAuthentication)
            }
        }
    }

    func testDenySucceedsWithStricterMissingOrInvalidPersistedPolicy() throws {
        for change in ["pause", "read-authentication", "timed-allowance", "missing", "invalid", "unreadable"] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            let second = try makeSecondVault(library)
            second.approvalRequests.configureAuthentication { _ in XCTFail("Deny must not authenticate"); return false }
            let ticket = try submitRead(second)
            switch change {
            case "pause": try library.vault.pauseAgentAccess(using: .allow)
            case "read-authentication": try library.vault.updateReadApprovalAuthentication(true)
            case "timed-allowance": try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
            case "missing": library.keys.policy = nil
            case "invalid": library.keys.policy = Data("invalid".utf8)
            default: library.keys.policyLoadFailure = SyntheticPolicyFailure()
            }
            library.keys.onPolicyLoad = { XCTFail("Deny must not read Keychain policy") }
            XCTAssertFalse(try second.agentAccessGate.beginExclusiveChange())
            defer { second.agentAccessGate.endExclusiveChange(paused: false) }
            XCTAssertEqual(try decide(second, ticket: ticket, decision: .deny).state, .denied, change)
            XCTAssertTrue(second.approvalRequests.pendingRequests().isEmpty)
            XCTAssertEqual(try decide(second, ticket: ticket, decision: .deny).state, .denied)
            library.keys.onPolicyLoad = nil
        }
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        _ = try library.vault.createFileCredential(.init(name: "FILE",
            snapshot: .init(originalFilename: "synthetic.txt", bytes: Data("synthetic".utf8)),
            environmentVariable: "FILE_PATH", permission: .allowed), using: .allow)
        try library.vault.beginManagementSession(using: .allow)
        _ = try library.vault.createTextCredential(.init(name: "ASK", value: "synthetic", environmentVariable: "TOKEN", permission: .ask), using: .allow)
        return library
    }

    private func makeSecondVault(_ library: AgentAccessPolicyLibrary) throws -> Vault {
        let manager = try FileDeliveryManager(rootURL: library.root.appendingPathComponent("second-deliveries"))
        let vault = Vault(store: try library.store, key: library.key, policyStore: library.keys, fileDeliveryManager: manager)
        vault.approvalRequests.configureAuthentication { _ in true }
        return vault
    }

    private func resolvedLease(_ vault: Vault) throws -> BrokerTextDeliveryLease {
        guard case let .resolved(_, _, lease) = try vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["FILE"]), cancellation: .init()
        ) else { throw SyntheticPolicyFailure() }
        return try XCTUnwrap(lease)
    }

    private func submitRead(_ vault: Vault) throws -> BrokerApprovalTicket {
        try vault.approvalRequests.submit(.init(operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
                                               operation: .read, payloadDigest: String(repeating: "a", count: 64)),
                                          trustedCredentialDeadline: .none)
    }

    private func decide(_ vault: Vault, ticket: BrokerApprovalTicket, decision: BrokerApprovalDecision = .once) throws -> BrokerApprovalTicket {
        try vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: decision)
    }

    private func persistedPolicy(_ library: AgentAccessPolicyLibrary) throws -> AgentAccessPolicy {
        try AgentAccessPolicyAuthentication.open(XCTUnwrap(library.keys.policy), using: library.key)
    }

    private func deliveryFiles(_ library: AgentAccessPolicyLibrary) throws -> [URL] {
        let root = library.root.appendingPathComponent("second-deliveries")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        return try (enumerator?.allObjects as? [URL] ?? []).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    private func askCredentialID(_ library: AgentAccessPolicyLibrary) throws -> String {
        try XCTUnwrap(library.store.fetchAllCredentials().first { $0.payloadKind == "text" }).id
    }
}

private final class AuthenticationPolicyChange: @unchecked Sendable {
    let library: AgentAccessPolicyLibrary
    let change: String
    var failure: Error?

    init(library: AgentAccessPolicyLibrary, change: String) { self.library = library; self.change = change }

    func apply() {
        do {
            switch change {
            case "pause": try library.vault.pauseAgentAccess(using: .allow)
            case "read-authentication": try library.vault.updateReadApprovalAuthentication(true)
            case "timed-allowance": try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
            default: library.keys.policy = nil
            }
        } catch { failure = error }
    }
}
