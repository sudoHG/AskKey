import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessPolicyConcurrencyTests: XCTestCase {
    func testExclusiveSettingsChangeCompletesDuringAuthenticationAndDecisionStillApplies() throws {
        let library = try makeLibrary()
        let ticket = try submitRead(library.vault)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        library.vault.approvalRequests.configureAuthentication { _ in
            entered.signal()
            return release.wait(timeout: .now() + 10) == .success
        }
        let decision = PolicyConcurrentOperation {
            _ = try library.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        }
        decision.start()
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let settings = PolicyConcurrentOperation { try library.vault.updateTimedAllowance(enabled: false, minutes: 15) }
        settings.start()
        XCTAssertEqual(settings.completion.wait(timeout: .now() + 1), .success,
                       "An exclusive change must finish while authentication is still waiting")
        release.signal()
        try settings.finish()
        try decision.finish()
        XCTAssertEqual(try library.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.timedAllowanceEnabled)
    }

    func testOwnTighteningKeepsPendingOnceApprovalsAndDeliveredFiles() throws {
        for setting in ["read-authentication", "timed-allowance"] {
            let library = try makeLibrary()
            try library.vault.updateReadApprovalAuthentication(false, using: .allow)
            let approved = try submitRead(library.vault)
            _ = try library.vault.decideAgentApproval(requestID: approved.requestID, capability: approved.capability, decision: .once)
            let pending = try submitRead(library.vault)
            let timed = try submitRead(library.vault)
            _ = try library.vault.decideAgentApproval(requestID: timed.requestID, capability: timed.capability,
                                                     decision: .timedAllow(duration: 60))
            let delivery = try library.manager.materialize(credentialID: "synthetic", bytes: Data("synthetic".utf8))
            if setting == "read-authentication" { try library.vault.updateReadApprovalAuthentication(true) }
            else { try library.vault.updateTimedAllowance(enabled: false, minutes: 30) }
            XCTAssertEqual(try library.vault.approvalRequests.status(requestID: approved.requestID, capability: approved.capability), .approved)
            XCTAssertEqual(try library.vault.approvalRequests.status(requestID: pending.requestID, capability: pending.capability), .pending)
            XCTAssertTrue(FileManager.default.fileExists(atPath: delivery.url.path))
            if setting == "timed-allowance" {
                XCTAssertNil(library.vault.approvalRequests.timedAllowanceDeadline(credentialID: "synthetic"))
            } else {
                library.vault.approvalRequests.configureAuthentication { _ in false }
                XCTAssertThrowsError(try library.vault.decideAgentApproval(
                    requestID: pending.requestID, capability: pending.capability, decision: .once
                )) { XCTAssertEqual($0 as? BrokerApprovalError, .authenticationFailed) }
            }
        }
    }

    func testAuthenticatedDecisionWaitsForAnExclusiveChangeAlreadyInProgress() throws {
        let library = try makeLibrary()
        let ticket = try submitRead(library.vault)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        library.vault.approvalRequests.configureAuthentication { _ in
            entered.signal()
            return release.wait(timeout: .now() + 5) == .success
        }
        let decision = PolicyConcurrentOperation {
            _ = try library.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability, decision: .once)
        }
        decision.start()
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        let paused = try library.vault.agentAccessGate.beginExclusiveChange()
        release.signal()
        XCTAssertEqual(decision.completion.wait(timeout: .now() + 0.1), .timedOut)
        library.vault.agentAccessGate.endExclusiveChange(paused: paused)
        try decision.finish()
        XCTAssertEqual(try library.vault.approvalRequests.status(requestID: ticket.requestID, capability: ticket.capability), .approved)
    }

    func testPostAuthenticationWaitIsBoundedWhenExclusiveChangeDoesNotFinish() throws {
        let library = try makeLibrary()
        let paused = try library.vault.agentAccessGate.beginExclusiveChange()
        defer { library.vault.agentAccessGate.endExclusiveChange(paused: paused) }
        let check = PolicyConcurrentOperation {
            try library.vault.agentAccessGate.beginSpawnAuthorization(waitForExclusiveChange: 0.05)
            library.vault.agentAccessGate.endSpawnAuthorization()
        }
        check.start()
        XCTAssertEqual(check.completion.wait(timeout: .now() + 1), .success)
        XCTAssertThrowsError(try check.finish()) {
            XCTAssertEqual($0 as? BrokerProviderError, .requestRejected)
        }
    }

    func testDisablingTimedAllowancePreservesRealOnceDeliveryButRevokesTimedDelivery() throws {
        for timed in [false, true] {
            let library = try makeLibrary()
            _ = try library.vault.createFileCredential(.init(name: "FILE",
                snapshot: .init(originalFilename: "synthetic.txt", bytes: Data("synthetic".utf8)),
                environmentVariable: "FILE_PATH", permission: .ask), using: .allow)
            library.vault.approvalRequests.configureAuthentication { _ in true }
            let request = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["FILE"])
            guard case let .approvalRequired(tickets) = try library.vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                return XCTFail("Expected an Ask approval")
            }
            let ticket = try XCTUnwrap(tickets.first)
            _ = try library.vault.decideAgentApproval(requestID: ticket.requestID, capability: ticket.capability,
                                                      decision: timed ? .timedAllow(duration: 60) : .once)
            guard case let .resolved(credentials, _, optionalLease) = try library.vault.brokerTextCredentials(for: request, cancellation: .init()) else {
                return XCTFail("Expected a real file delivery")
            }
            let lease = try XCTUnwrap(optionalLease)
            defer { lease.finish(); lease.cleanup() }
            let path = try XCTUnwrap(credentials.first).value
            try lease.performAuthorizedSpawn(afterAuthorization: {}, spawn: {})
            lease.finish() // The target has crossed spawn; keep its files and runtime authorization alive.
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
            XCTAssertEqual(FileManager.default.fileExists(atPath: path), !timed)
            lease.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testRuntimeTighteningAndRecoveryPublishPolicyNotifications() throws {
        for recovery in [false, true] {
            let library = try makeLibrary()
            let drained = expectation(description: "Earlier policy notifications delivered")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: 2)
            let changed = expectation(forNotification: .askKeyAgentAccessPolicyDidChange, object: nil)
            if recovery { library.keys.policy = nil }
            else {
                var policy = try library.vault.agentAccessPolicyState().policy
                policy.paused = true
                library.keys.policy = try AgentAccessPolicyAuthentication.seal(policy, using: library.key)
            }
            XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
            wait(for: [changed], timeout: 2)
            XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
            XCTAssertEqual(try library.vault.agentAccessPolicyState().needsRecovery, recovery)
        }
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        return library
    }

    private func submitRead(_ vault: Vault) throws -> BrokerApprovalTicket {
        try vault.approvalRequests.submit(.init(operationID: UUID().uuidString, credentialID: "synthetic", targetID: "synthetic",
                                               operation: .read, payloadDigest: String(repeating: "a", count: 64)),
                                          trustedCredentialDeadline: .none)
    }
}

private final class PolicyConcurrentOperation: @unchecked Sendable {
    let completion = DispatchGroup()
    private let operation: () throws -> Void
    private var failure: Error?

    init(_ operation: @escaping () throws -> Void) { self.operation = operation }

    func start() {
        completion.enter()
        DispatchQueue.global().async {
            defer { self.completion.leave() }
            do { try self.operation() }
            catch { self.failure = error }
        }
    }

    func finish() throws {
        guard completion.wait(timeout: .now() + 5) == .success else { throw SyntheticPolicyFailure() }
        if let failure { throw failure }
    }
}
