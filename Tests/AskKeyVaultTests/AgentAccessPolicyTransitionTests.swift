import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class AgentAccessPolicyTransitionTests: XCTestCase {
    func testReopenPausesGateBeforeLoadingPolicyAndPublishingStore() throws {
        let library = try makeLibrary()
        let oldStore = try library.store
        let loading = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        library.keys.onPolicyLoad = {
            loading.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let operation = PolicyReopenOperation(library.vault)
        operation.start()
        defer { release.signal() }
        XCTAssertEqual(loading.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(try library.store === oldStore)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
        release.signal()
        try operation.finish()
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
        XCTAssertFalse(try library.store === oldStore)
    }

    func testEarlierExclusiveChangeCannotRestoreActiveOverFailClosedReopen() throws {
        let library = try makeLibrary()
        library.keys.policy = nil
        let loading = DispatchSemaphore(value: 0)
        library.keys.onPolicyLoad = { loading.signal() }
        XCTAssertFalse(try library.vault.agentAccessGate.beginExclusiveChange())
        let operation = PolicyReopenOperation(library.vault)
        operation.start()
        XCTAssertEqual(loading.wait(timeout: .now() + 0.1), .timedOut)
        library.vault.agentAccessGate.endExclusiveChange(paused: false)
        try operation.finish()
        XCTAssertEqual(loading.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertTrue(try library.vault.agentAccessPolicyState().needsRecovery)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
    }

    func testFailedBootstrapQuiescesExistingRuntimeAndCleansDeliveries() throws {
        let library = try makeLibrary()
        let delivery = try library.manager.materialize(credentialID: "synthetic", bytes: Data("synthetic".utf8))
        library.keys.appKey = nil
        XCTAssertThrowsError(try library.vault.unlock())
        XCTAssertTrue(library.vault.isLocked)
        XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
        XCTAssertThrowsError(try library.vault.approvalRequests.submit(.init(
            operationID: "failed-open", credentialID: "synthetic", targetID: "synthetic",
            operation: .read, payloadDigest: String(repeating: "a", count: 64)
        ), trustedCredentialDeadline: .none))
    }

    func testFailedLocalEraseProjectsActualGateEvenWhenSavedPolicyIsActive() throws {
        let library = try makeLibrary()
        let coordinator = library.vault.makeLocalEraseCoordinator(
            journal: FileLocalVaultEraseJournalStore(url: library.root.appendingPathComponent("erase.journal")),
            deleteEncryptedData: { throw SyntheticPolicyFailure() },
            deleteLocalKey: { XCTFail("Keys must survive failed data deletion") }
        )
        XCTAssertThrowsError(try coordinator.erase(confirmation: "ERASE", language: .english, using: .allow))
        let state = try library.vault.agentAccessPolicyState()
        XCTAssertFalse(state.policy.paused)
        XCTAssertTrue(state.isPaused)
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
    }

    func testVaultLockPausesGateAndCleansExistingDeliveries() throws {
        let library = try makeLibrary()
        let delivery = try library.manager.materialize(credentialID: "synthetic", bytes: Data("synthetic".utf8))
        library.vault.lock()
        XCTAssertTrue(try library.vault.agentAccessPolicyState().isPaused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: delivery.url.path))
        try library.vault.unlock()
        XCTAssertFalse(try library.vault.isAgentAccessPaused())
    }

    func testSettingsSaveCannotLiftAnExistingLocalLifecycleGatePause() throws {
        let library = try makeLibrary()
        XCTAssertFalse(try library.vault.agentAccessGate.beginExclusiveChange())
        library.vault.agentAccessGate.endExclusiveChange(paused: true)
        try library.vault.updateTimedAllowance(enabled: true, minutes: 30)
        XCTAssertFalse(try library.vault.agentAccessPolicyState().policy.paused)
        XCTAssertTrue(try library.vault.isAgentAccessPaused())
        XCTAssertThrowsError(try library.vault.brokerCredentialCatalog())
    }

    private func makeLibrary() throws -> AgentAccessPolicyLibrary {
        let library = try AgentAccessPolicyLibrary()
        addTeardownBlock { try library.close() }
        return library
    }
}

private final class PolicyReopenOperation: @unchecked Sendable {
    private let vault: Vault
    private let finished = DispatchSemaphore(value: 0)
    private var failure: Error?

    init(_ vault: Vault) { self.vault = vault }

    func start() {
        DispatchQueue.global().async {
            defer { self.finished.signal() }
            do { try self.vault.unlock() }
            catch { self.failure = error }
        }
    }

    func finish() throws {
        guard finished.wait(timeout: .now() + 5) == .success else { throw SyntheticPolicyFailure() }
        if let failure { throw failure }
    }
}
