import Darwin
import Dispatch
import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyVault

final class RuntimeApprovalConsumptionTests: RuntimeApprovalBoundaryTestSupport {
    func testValidConsumedApprovalsDeliverTheWholeRequestedSetOnce() throws {
        for shape in ApprovalDeliveryShape.allCases {
            for once in [false, true] {
                let harness = try makeHarness(shape: shape)
                let runtime = harness.runtime()
                try harness.approve(request: harness.request, runtime: runtime, once: once)
                XCTAssertEqual(try harness.run(runtime), .exited(0), "\(shape), once=\(once)")
                XCTAssertEqual(try harness.run(runtime), .exited(0), "retransmission must reuse its result")
                XCTAssertEqual(harness.targetStarts, 1)
                XCTAssertEqual(harness.deliveredKinds, shape.expectedKinds)
                XCTAssertTrue(harness.payloadFiles.isEmpty)
            }
        }
    }
    func testRevocationAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .revoke)
    }
    func testTimedExpiryAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .timedExpiry)
    }
    func testOnceExpiryAfterConsumptionPreventsTextFileAndMixedTargets() throws {
        try assertRejectedBeforeSpawn(event: .onceExpiry)
    }
    func testNewTimedApprovalCannotReviveARevokedOrExpiredConsumedOperation() throws {
        for event in [ApprovalBoundaryEvent.revoke, .timedExpiry] {
            try assertRejectedBeforeSpawn(event: event, grantAgain: true)
        }
    }
    func testRevocationOrExpiryBeforeFileRegistrationPreventsTheWholeTargetAndCleansUp() throws {
        for shape in [ApprovalDeliveryShape.file, .mixed] {
            for event in ApprovalBoundaryEvent.allCases {
                let harness = try makeHarness(shape: shape)
                let runtime = harness.runtime()
                try harness.approve(request: harness.request, runtime: runtime, once: event == .onceExpiry)
                harness.registrationHook.install {
                    try harness.invalidateConsumedApproval(event)
                }
                assertRejectedAndClean(harness, runtime: runtime, hook: harness.registrationHook,
                                       message: "\(shape), registration, \(event)")
            }
        }
    }
    func testRevocationCannotCompleteInsideTheFinalAuthorizedSpawn() throws {
        let harness = try makeHarness(shape: .mixed)
        let attempted = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let completed = ApprovalBoundaryFlag()
        let runtime = harness.runtime(afterAuthorization: {
            DispatchQueue.global().async {
                attempted.signal()
                _ = harness.approvals.revokeTimedAllowance(credentialID: harness.revokedCredentialID)
                completed.set()
                finished.signal()
            }
            guard attempted.wait(timeout: .now() + 2) == .success else {
                throw ApprovalBoundaryTestError.timeout("revocation worker did not start")
            }
            // The target owns the final authorization boundary. Revocation must
            // serialize after spawn, rather than finish between check and spawn.
            XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        })
        try harness.approve(request: harness.request, runtime: runtime)
        let result = Result { try harness.run(runtime) }
        let workerFinished = completed.value || finished.wait(timeout: .now() + 3) == .success
        XCTAssertTrue(workerFinished, "release all spawn locks even when spawning fails")
        XCTAssertEqual(try result.get(), .exited(0))
        XCTAssertEqual(harness.targetStarts, 1)
        XCTAssertTrue(harness.payloadFiles.isEmpty)
    }
    func testAlreadySpawnedTargetsMayFinishButRevocationAndApprovalExpiryCleanFiles() throws {
        for shape in ApprovalDeliveryShape.allCases {
            for event in ApprovalBoundaryEvent.allCases {
                let harness = try makeHarness(shape: shape)
                let afterSpawn = ApprovalBoundaryHook()
                let runtime = harness.runtime(afterSpawn: { try afterSpawn.fire() })
                try harness.approve(request: harness.request, runtime: runtime, once: event == .onceExpiry)
                afterSpawn.install {
                    try harness.invalidateConsumedApproval(event)
                    // Runtime's final cleanup has not run. The file TTL is 300 s;
                    // logical approval expiry (30/120 s) must clean it independently.
                    guard harness.payloadFiles.isEmpty else {
                        throw ApprovalBoundaryTestError.filesSurvivedApprovalInvalidation
                    }
                }
                XCTAssertEqual(try harness.run(runtime), .exited(0), "\(shape), \(event)")
                assertHookFinished(afterSpawn)
                XCTAssertEqual(harness.targetStarts, 1)
                XCTAssertTrue(harness.payloadFiles.isEmpty)
            }
        }
    }
}
