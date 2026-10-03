import Darwin
import Dispatch
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class RuntimeApprovalCleanupTests: RuntimeApprovalBoundaryTestSupport {
    func testRejectedRuntimeReportsFailedFileRemovalAndRetriesWithoutStartingTheTarget() throws {
        let removal = ApprovalBoundaryFailingRemoval()
        let harness = try ApprovalBoundaryHarness(shape: .file, cleanupRetryDelay: 60,
                                                 removeItem: { try removal.remove($0) })
        addTeardownBlock {
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        let hook = ApprovalBoundaryHook()
        let sawFailure = ApprovalBoundaryFlag()
        let runtime = harness.runtime(beforeSpawn: { try hook.fire() })
        try harness.approve(request: harness.request, runtime: runtime)
        hook.install {
            try harness.invalidateConsumedApproval(.revoke)
            guard harness.manager.cleanupFailures.count == 1,
                  harness.payloadFiles.count == 1 else {
                throw ApprovalBoundaryTestError.invalidFixtureState("failed deletion must remain visible")
            }
            sawFailure.set()
        }
        assertRejectedAndClean(harness, runtime: runtime, hook: hook, message: "failed revoke cleanup")
        XCTAssertTrue(sawFailure.value)
        XCTAssertGreaterThanOrEqual(removal.attempts, 2)
        XCTAssertTrue(harness.manager.cleanupFailures.isEmpty)
    }
    func testOriginalApprovalDeadlineIsCheckedAgainAtTheActualSystemSpawn() throws {
        let harness = try ApprovalBoundaryHarness(shape: .text, useLiveApprovalClock: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        let deadline = ApprovalBoundaryDeadline()
        let reachedSystemBoundary = ApprovalBoundaryFlag()
        let runtime = harness.runtime(beforeSystemSpawn: {
            reachedSystemBoundary.set()
            let remaining = deadline.value.timeIntervalSinceNow
            guard remaining > 0, remaining < 2 else {
                throw ApprovalBoundaryTestError.invalidFixtureState("deadline must still be future at the system boundary")
            }
            // Deliberately real time: the C layer reads CLOCK_REALTIME. Injected
            // state-machine time cannot prove this final deadline propagation.
            Thread.sleep(forTimeInterval: remaining + 0.02)
        })
        try harness.approve(request: harness.request, runtime: runtime, timedDuration: 1)
        deadline.set(try XCTUnwrap(harness.approvals.timedAllowanceDeadline(
            credentialID: harness.revokedCredentialID
        )))
        XCTAssertThrowsError(try harness.run(runtime)) {
            XCTAssertEqual($0 as? BrokerProviderError, .requestRejected)
        }
        XCTAssertTrue(reachedSystemBoundary.value)
        XCTAssertEqual(harness.targetStarts, 0)
    }
    func testFailureAtEitherFinalSpawnHookReleasesApprovalAndVaultLocks() throws {
        for beforeSystemCall in [false, true] {
            let harness = try makeHarness(shape: .mixed)
            let fail: BrokerTextRuntime.SpawnBoundaryHook = { throw BrokerTextRuntimeError.spawnFailed }
            let noop: BrokerTextRuntime.SpawnBoundaryHook = {}
            let runtime = harness.runtime(afterAuthorization: beforeSystemCall ? noop : fail,
                                          beforeSystemSpawn: beforeSystemCall ? fail : noop)
            try harness.approve(request: harness.request, runtime: runtime)
            XCTAssertThrowsError(try harness.run(runtime))
            let followup = ApprovalBoundaryHook()
            followup.install {
                _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
                try harness.vault.pauseAgentAccess(using: .allow)
            }
            XCTAssertNoThrow(try followup.fire())
            assertHookFinished(followup)
            XCTAssertEqual(harness.targetStarts, 0)
            XCTAssertTrue(harness.payloadFiles.isEmpty)
        }
    }
    func testDelayedOldFileCleanupCannotDeleteANewlyApprovedDelivery() throws {
        let removal = ApprovalBoundaryDelayedRemoval()
        let harness = try ApprovalBoundaryHarness(shape: .file, removeItem: { try removal.remove($0) })
        let oldReady = DispatchSemaphore(value: 0)
        let resumeOld = DispatchSemaphore(value: 0)
        let oldDone = DispatchGroup()
        let revokeDone = DispatchGroup()
        let oldResult = ApprovalBoundaryRuntimeResult()
        defer {
            resumeOld.signal()
            removal.release.signal()
            _ = oldDone.wait(timeout: .now() + 3)
            _ = revokeDone.wait(timeout: .now() + 3)
        }
        addTeardownBlock {
            guard oldDone.wait(timeout: .now() + 3) == .success,
                  revokeDone.wait(timeout: .now() + 3) == .success else { return }
            harness.manager.cleanupAll()
            try? FileManager.default.removeItem(at: harness.root)
        }
        let oldRuntime = harness.runtime(beforeSpawn: {
            oldReady.signal()
            guard resumeOld.wait(timeout: .now() + 3) == .success else {
                throw ApprovalBoundaryTestError.timeout("old runtime was not resumed")
            }
        })
        try harness.approve(request: harness.request, runtime: oldRuntime)
        oldDone.enter()
        DispatchQueue.global().async {
            defer { oldDone.leave() }
            oldResult.store(Result { try harness.run(oldRuntime) })
        }
        guard oldReady.wait(timeout: .now() + 2) == .success else {
            return XCTFail("old runtime did not reach its materialized-file boundary")
        }
        let oldFiles = Set(harness.payloadFiles)
        XCTAssertEqual(oldFiles.count, 1)
        revokeDone.enter()
        DispatchQueue.global().async {
            defer { revokeDone.leave() }
            _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
        }
        guard removal.entered.wait(timeout: .now() + 2) == .success else {
            return XCTFail("old cleanup did not begin")
        }
        try harness.grantNewOperation()
        let fresh = try XCTUnwrap(harness.renewedRequest)
        let freshRuntime = harness.runtime(beforeSpawn: {
            let freshFiles = Set(harness.payloadFiles).subtracting(oldFiles)
            removal.release.signal()
            guard revokeDone.wait(timeout: .now() + 2) == .success, freshFiles.count == 1,
                  freshFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw ApprovalBoundaryTestError.invalidFixtureState("old cleanup removed or blocked the new delivery")
            }
        })
        XCTAssertEqual(try harness.run(freshRuntime, request: fresh), .exited(0))
        XCTAssertEqual(harness.deliveredKinds, Set(["file"]))
        resumeOld.signal()
        XCTAssertEqual(oldDone.wait(timeout: .now() + 3), .success)
        guard case .failure(let error) = try XCTUnwrap(oldResult.value) else {
            return XCTFail("the revoked old runtime must be refused")
        }
        XCTAssertEqual(error as? BrokerProviderError, .requestRejected)
        XCTAssertEqual(harness.targetStarts, 1, "only the new authorization may start a target")
        XCTAssertTrue(harness.payloadFiles.isEmpty)
        XCTAssertFalse(removal.timedOut)
    }
}
