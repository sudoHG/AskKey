import Darwin
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessPolicyOwnershipTests: XCTestCase {
    func testReplacedSocketRevokesOldOwnersWritesBeforeAuthentication() throws {
        for operation in ["pause", "resume", "settings", "read-authentication"] {
            let library = try makeLibrary()
            let path = try makeSocketPath()
            let owner = makeServer(path)
            try owner.start()
            defer { owner.stop() }
            try library.vault.setAgentAccessPolicyOwnership(true, validateOwnership: { owner.ownsSocketPath })
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
                case "pause": try library.vault.pauseAgentAccess(using: authenticator)
                case "resume": try library.vault.resumeAgentAccess(using: authenticator)
                case "read-authentication": try library.vault.updateReadApprovalAuthentication(false, using: authenticator)
                default: try library.vault.updateTimedAllowance(enabled: false, minutes: 15)
                }
            }()) { XCTAssertEqual(($0 as? AgentAccessPolicyError)?.errorDescription,
                                 AgentAccessPolicyError.ownershipRevoked.errorDescription) }
            library.keys.onPolicyLoad = nil
            XCTAssertEqual(authentication.count, 0)
            XCTAssertEqual(library.keys.policy, saved)
            XCTAssertEqual(library.keys.policyWrites, writes)
            XCTAssertThrowsError(try library.vault.validateAgentAccessPolicyOwnership())
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
        try library.vault.setAgentAccessPolicyOwnership(true, validateOwnership: { owner.ownsSocketPath })
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
            XCTAssertEqual(($0 as? AgentAccessPolicyError)?.errorDescription,
                           AgentAccessPolicyError.ownershipRevoked.errorDescription)
        }
        XCTAssertNil(replacementFailure)
        XCTAssertEqual(library.keys.policyWrites, writes)
        XCTAssertEqual(library.keys.policy, saved)
        XCTAssertTrue(replacement.ownsSocketPath)
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
}

private final class OwnershipAuthenticationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
