import AppKit
import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyCore

final class AgentOnboardingEvidenceCloseTests: AskKeyAppTestCase {
    func testTerminateLaterApplyFailureRepliesExactlyOnceThroughAppGate() async {
        let replies = LockedMutationCount()
        let gate = CloseApplyGate()
        let probe = RepairCloseProbe()
        probe.checkHandler = { client, _ in
            AgentCheckReport(
                outcome: .notConfigured,
                targetSummary: client.rawValue,
                plan: closeSamplePlan(client),
                failure: nil
            )
        }
        probe.applyHandler = { _, _, _ in
            await gate.wait()
            throw AgentOnboardingFailure.verificationFailed
        }
        let coordinator = await MainActor.run {
            AgentOnboardingCoordinator(operations: probe.operations)
        }
        await coordinator.startCheck(.codex)
        let confirm = Task { await coordinator.confirm(.codex) }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if probe.applyCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let decision = await MainActor.run {
            OnboardingTerminationGate.shouldTerminate(
                hasInFlightWrite: coordinator.hasInFlightWrite,
                arm: { coordinator.writeSettledHandler = $0 },
                reply: { _ in replies.add() }
            )
        }
        XCTAssertEqual(decision, .terminateLater)
        gate.release()
        await confirm.value
        XCTAssertEqual(replies.value, 1)
        XCTAssertEqual(probe.applyCount, 1)
        await MainActor.run { coordinator.notifyWriteSettledIfNeeded() }
        XCTAssertEqual(replies.value, 1)
        let session = await MainActor.run { coordinator.session(for: .codex) }
        XCTAssertEqual(session.attempt.failure, .verificationFailed)
    }

}

private final class CloseApplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if released {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
    }

    func release() {
        lock.withLock {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}

private final class LockedMutationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    func add() { lock.withLock { storage += 1 } }
    var value: Int { lock.withLock { storage } }
}

private final class RepairCloseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var applies = 0
    var checkHandler: (@Sendable (AgentClient, AgentCheckCancellation) async throws -> AgentCheckReport)?
    var applyHandler: (@Sendable (AgentClient, AgentOnboardingPlan, AgentCheckCancellation) async throws -> AgentApplyReport)?
    var applyCount: Int { lock.withLock { applies } }

    var operations: AgentOnboardingOperations {
        AgentOnboardingOperations(
            check: { client, cancellation in
                if let checkHandler = self.checkHandler {
                    return try await checkHandler(client, cancellation)
                }
                return AgentCheckReport(outcome: .notConfigured, targetSummary: "", plan: nil, failure: nil)
            },
            apply: { client, plan, cancellation in
                self.lock.withLock { self.applies += 1 }
                if let applyHandler = self.applyHandler {
                    return try await applyHandler(client, plan, cancellation)
                }
                return AgentApplyReport(
                    outcome: .notConfigured,
                    changeStatus: .notWritten,
                    failure: .cancelled,
                    targetSummary: ""
                )
            },
            authenticate: { .confirmed }
        )
    }
}

private func closeSamplePlan(_ client: AgentClient) -> AgentOnboardingPlan {
    AgentOnboardingPlan(
        client: client,
        createdAt: Date(timeIntervalSince1970: 1),
        targetIdentity: client.rawValue,
        scopeSummary: "scope",
        configurationPresent: false,
        verifiesOnly: false,
        preconditionSummary: "backup"
    )
}
