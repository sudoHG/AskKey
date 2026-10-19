import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessPolicyOwnershipTests: XCTestCase {
    func testReplacedSocketRevokesRelaxingWritesBeforeAuthenticationAndStopsBroker() throws {
        for operation in ["resume", "settings", "read-authentication"] {
            let library = try makeLibrary()
            let path = try makeSocketPath()
            let owner = makeServer(path)
            try owner.start()
            defer { owner.stop() }
            try grantOwnership(library.vault, to: owner)
            XCTAssertEqual(unlink(path), 0)
            let replacement = makeServer(path)
            try replacement.start()
            defer { replacement.stop() }
            let saved = library.keys.policy
            let writes = library.keys.policyWrites
            let authentication = OwnershipAuthenticationRecorder()
            let authenticator = ManagementAuthenticator { _ in authentication.record(); return true }
            library.keys.onPolicyLoad = { XCTFail("A revoked owner must refuse before reading for a write") }
            XCTAssertThrowsError(try {
                switch operation {
                case "resume": try library.vault.resumeAgentAccess(using: authenticator)
                case "read-authentication": try library.vault.updateReadApprovalAuthentication(false, using: authenticator)
                default: try library.vault.updateTimedAllowance(enabled: true, minutes: 120)
                }
            }()) { XCTAssertEqual(($0 as? AgentAccessPolicyError)?.errorDescription,
                                 AgentAccessPolicyError.ownershipRevoked.errorDescription) }
            library.keys.onPolicyLoad = nil
            XCTAssertEqual(authentication.count, 0)
            XCTAssertEqual(library.keys.policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            XCTAssertThrowsError(try library.vault.validateAgentAccessPolicyOwnership())
            XCTAssertFalse(owner.isRunning)
            XCTAssertTrue(try library.vault.isAgentAccessPaused())
            XCTAssertTrue(replacement.ownsSocketPath)
        }
    }

    func testSocketReplacementAfterPreflightIsStillRefusedAtWriteTime() throws {
        let library = try makeLibrary()
        let path = try makeSocketPath()
        let owner = makeServer(path)
        try owner.start()
        defer { owner.stop() }
        let replacement = makeServer(path)
        defer { replacement.stop() }
        try grantOwnership(library.vault, to: owner)
        let saved = library.keys.policy
        let writes = library.keys.policyWrites
        var replacementFailure: Error?
        library.keys.onPolicyLoad = {
            library.keys.onPolicyLoad = nil
            XCTAssertEqual(unlink(path), 0)
            do { try replacement.start() }
            catch { replacementFailure = error }
        }
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: false, minutes: 15)) {
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, .settings)
        }
        XCTAssertNil(replacementFailure)
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertFalse(owner.isRunning)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.timedAllowanceEnabled)
        XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
        XCTAssertTrue(replacement.ownsSocketPath)
    }

    func testLinkToOriginalSocketRefusesRequestStopsBrokerAndQuiescesVault() throws {
        let library = try makeLibrary()
        let path = try makeSocketPath()
        let catalogCalls = OwnershipAuthenticationRecorder()
        let revoked = OwnershipAuthenticationRecorder()
        let owner = BrokerSocketServer(socketPath: path, handler: .init(catalog: { _ in
            catalogCalls.record()
            return []
        }, requestStatus: { _, _ in nil }))
        try owner.start()
        defer { owner.stop() }
        let stopped = expectation(description: "Ownership loss quiesced the Vault")
        owner.setOwnershipLossHandler {
            try? library.vault.validateAgentAccessPolicyOwnership()
            stopped.fulfill()
        }
        try library.vault.setAgentAccessPolicyOwnership(true, validateOwnership: { owner.ownsSocketPath }, onRevocation: { _ in
            revoked.record()
            owner.stop()
        })
        let (url, lease) = try deliverFile(library)
        defer { lease.cleanup() }
        let original = path + ".original"
        try FileManager.default.moveItem(atPath: path, toPath: original)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: original)
        do {
            XCTAssertEqual(try BrokerSocketClient(socketPath: path).send(.init(version: 1, method: "catalog")),
                           .failure(.agentAccessPaused))
        } catch { /* Closing the listener may reject the write before the refusal frame is read. */ }
        wait(for: [stopped], timeout: 3)
        XCTAssertEqual(catalogCalls.count, 0)
        XCTAssertEqual(revoked.count, 1)
        XCTAssertFalse(owner.isRunning)
        XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertThrowsError(try BrokerSocketClient(socketPath: original).send(.init(version: 1, method: "health")))
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        XCTAssertEqual(revoked.count, 1)
    }

    func testPauseWithoutOwnershipCleansDeliveriesAndReturnsUnsavedPauseWithoutReadingPolicy() throws {
        for unavailable in [false, true] {
            let library = try makeLibrary()
            let owner = makeServer(try makeSocketPath())
            try owner.start()
            defer { owner.stop() }
            try grantOwnership(library.vault, to: owner)
            let (url, lease) = try deliverFile(library)
            defer { lease.cleanup() }
            let ticket = try library.vault.approvalRequests.submit(
                .init(operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic", operation: .read,
                      payloadDigest: String(repeating: "a", count: 64)), trustedCredentialDeadline: .none)
            if unavailable { try library.vault.setAgentAccessPolicyOwnership(false) }
            else { owner.stop() }
            let saved = library.keys.policy
            let writes = library.keys.policyWrites
            library.keys.onPolicyLoad = { XCTFail("Local Pause must precede and survive policy access") }
            XCTAssertNoThrow(try library.vault.pauseAgentAccess(using: .allow))
            library.keys.onPolicyLoad = nil
            let state = try library.vault.agentAccessPolicyState()
            XCTAssertTrue(state.isPaused)
            XCTAssertTrue(state.policy.paused)
            XCTAssertTrue(state.pauseNotPersisted)
            XCTAssertEqual(state.saveFailure?.operation, .pause)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try library.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .cancelled)
            XCTAssertEqual(library.keys.policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            let later = try library.manager.materialize(credentialID: "synthetic", bytes: Data("synthetic".utf8))
            XCTAssertNoThrow(try library.vault.pauseAgentAccess(using: .allow))
            XCTAssertFalse(FileManager.default.fileExists(atPath: later.url.path))
        }
    }

    func testNonOwnerTighteningAppliesLocallyWithoutSavingAndSurvivesReopen() throws {
        let library = try makeLibrary()
        try library.vault.updateReadApprovalAuthentication(false, using: .allow)
        let saved = library.keys.policy
        let writes = library.keys.policyWrites
        try library.vault.setAgentAccessPolicyOwnership(false)
        XCTAssertThrowsError(try library.vault.updateReadApprovalAuthentication(true)) {
            XCTAssertEqual(($0 as? AgentAccessPolicySaveFailure)?.operation, .settings)
        }
        XCTAssertThrowsError(try library.vault.updateTimedAllowance(enabled: false, minutes: 15))
        try library.reopen()
        let state = try library.vault.agentAccessPolicyState()
        XCTAssertTrue(state.policy.readApprovalAuthentication)
        XCTAssertFalse(state.policy.timedAllowanceEnabled)
        XCTAssertEqual(state.policy.timedAllowanceMinutes, 15)
        XCTAssertTrue(state.isPaused)
        XCTAssertTrue(state.pauseNotPersisted)
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertEqual(library.keys.policyWrites, writes)
    }

    func testFreshBindRegainsOwnershipAndAuthenticatedResumeRestoresServing() throws {
        let library = try makeLibrary()
        let path = try makeSocketPath()
        let old = makeServer(path)
        try old.start()
        defer { old.stop() }
        try grantOwnership(library.vault, to: old)
        try FileManager.default.removeItem(atPath: path)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        XCTAssertFalse(old.isRunning)
        let fresh = makeServer(path)
        try fresh.start()
        defer { fresh.stop() }
        try grantOwnership(library.vault, to: fresh)
        XCTAssertNoThrow(try library.vault.validateAgentAccessPolicyOwnership())
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        try library.vault.resumeAgentAccess(using: .allow)
        XCTAssertNoThrow(try library.vault.brokerCredentialCatalog())
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(fresh.isRunning)
    }

    func testSocketLossAtFinalBoundaryPausesWithoutWaitingForItsOwnLease() throws {
        let library = try makeLibrary()
        let path = try makeSocketPath()
        let owner = makeServer(path)
        try owner.start()
        defer { owner.stop() }
        try grantOwnership(library.vault, to: owner)
        _ = try library.vault.createFileCredential(.init(name: "FILE", snapshot: .init(originalFilename: "synthetic.txt",
            bytes: Data("synthetic".utf8)), environmentVariable: "FILE_PATH", permission: .allowed), using: .allow)
        guard case let .resolved(credentials, _, optionalLease) = try library.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["FILE"]), cancellation: .init()
        ), let lease = optionalLease, let credential = credentials.first else { return XCTFail("Expected a file delivery") }
        defer { lease.finish(); lease.cleanup() }
        try FileManager.default.removeItem(atPath: path)
        var spawned = false
        XCTAssertThrowsError(try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: { spawned = true }))
        XCTAssertFalse(spawned)
        XCTAssertFalse(owner.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credential.value))
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
    }

    func testNonOwnerGenuineCreationBecomesOwnerWithoutPolicyRecoveryOrResume() throws {
        let library = try makeLibrary(open: false)
        try library.vault.setAgentAccessPolicyOwnership(false)
        try library.reopen()
        XCTAssertEqual(try library.vault.agentAccessPolicyState().policy, .defaults)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().needsRecovery)
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
        XCTAssertEqual(library.keys.policyWrites, 1)
        XCTAssertNoThrow(try library.vault.beginOnboardingCreation())
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
        try library.vault.setAgentAccessPolicyOwnership(true)
        XCTAssertNoThrow(try library.vault.brokerCredentialCatalog())
        XCTAssertNoThrow(try library.vault.updateTimedAllowance(enabled: true, minutes: 15))
        XCTAssertFalse(try library.vault.agentAccessPolicyState().needsRecovery)
    }

    func testOwnershipErrorDuringAdoptionNeverLatchesPolicyRecovery() throws {
        let library = try makeLibrary(open: false)
        library.keys.policySaveFailure = AgentAccessPolicyError.notOwner
        XCTAssertThrowsError(try library.reopen())
        XCTAssertFalse(library.vault.agentAccessPolicyLatches().recovery)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().needsRecovery)
    }

    private func makeLibrary(open: Bool = true) throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary(open: open)
        addTeardownBlock { try library.close() }
        return library
    }

    private func makeSocketPath() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ak-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("broker.sock").path
    }

    private func makeServer(_ path: String) -> BrokerSocketServer {
        .init(socketPath: path, handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil }))
    }

    private func grantOwnership(_ vault: Vault, to server: BrokerSocketServer) throws {
        server.setOwnershipLossHandler { try? vault.validateAgentAccessPolicyOwnership() }
        try vault.setAgentAccessPolicyOwnership(true, validateOwnership: { server.ownsSocketPath },
                                               onRevocation: { _ in server.stop() })
    }

    private func deliverFile(_ library: AgentAccessPolicyLibrary) throws -> (URL, BrokerTextDeliveryLease) {
        _ = try library.vault.createFileCredential(.init(name: "FILE", snapshot: .init(originalFilename: "synthetic.txt",
            bytes: Data("synthetic".utf8)), environmentVariable: "FILE_PATH", permission: .allowed), using: .allow)
        guard case let .resolved(credentials, _, optionalLease) = try library.vault.brokerTextCredentials(
            for: .init(command: ["/usr/bin/true"], credentialNames: ["FILE"]), cancellation: .init()
        ), let lease = optionalLease, let credential = credentials.first else { throw SyntheticPolicyFailure() }
        try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
        lease.finish()
        return (URL(fileURLWithPath: credential.value), lease)
    }
}

private final class OwnershipAuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
