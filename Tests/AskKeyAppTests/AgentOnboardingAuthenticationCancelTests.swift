import Foundation
import XCTest
@testable import AskKeyAppKit

@MainActor
final class AgentOnboardingAuthenticationCancelTests: AskKeyAppTestCase {
    func testCancelCollapseDisappearAndAbandonPropagateAndRejectLateSuccess() async {
        for action in ["cancel", "collapse", "disappear", "abandon"] {
            let started = expectation(description: "authentication started")
            let cancelled = expectation(description: "authentication cancelled by \(action)")
            var continuation: CheckedContinuation<AgentAuthenticationOutcome, Never>?
            var calls = 0
            var applies = 0
            let operations = AgentOnboardingOperations(
                check: { _, _ in
                    AgentCheckReport(outcome: .notConfigured, targetSummary: "synthetic", plan: nil, failure: nil)
                },
                apply: { _, _, _ in
                    XCTFail("cancelled authentication must not apply")
                    return AgentApplyReport(outcome: .notConfigured, changeStatus: .notWritten, failure: nil, targetSummary: "")
                },
                authenticate: {
                    calls += 1
                    if calls > 1 { return .cancelled }
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation {
                            continuation = $0
                            started.fulfill()
                        }
                    } onCancel: {
                        cancelled.fulfill()
                    }
                },
                revalidateWriteSession: { applies += 1; return true }
            )
            var session = AgentClientOnboardingSession.idle
            session.plan = AgentOnboardingPlan(
                client: .codex, createdAt: Date(), targetIdentity: "synthetic", scopeSummary: "synthetic",
                configurationPresent: false, verifiesOnly: false, preconditionSummary: "synthetic"
            )
            session.attempt.phase = .readyToConfirm
            let coordinator = AgentOnboardingCoordinator(operations: operations, initialSessions: [.codex: session])
            coordinator.explain(.codex)
            let pending = Task { await coordinator.confirm(.codex) }
            await fulfillment(of: [started], timeout: 2)
            switch action {
            case "cancel": coordinator.cancelAuthentication(.codex)
            case "collapse": coordinator.collapse()
            case "disappear": coordinator.disappear()
            default: coordinator.abandonOperation(for: .codex, returningTo: .readyToConfirm)
            }
            await fulfillment(of: [cancelled], timeout: 2)
            await coordinator.confirm(.codex)
            XCTAssertEqual(calls, 2, "cancellation releases the authentication slot before a late callback")
            continuation?.resume(returning: .confirmed)
            await pending.value
            XCTAssertEqual(applies, 0)
            XCTAssertFalse(coordinator.hasInFlightWrite)
            XCTAssertEqual(coordinator.session(for: .codex).attempt.phase, .readyToConfirm)
        }
    }
}
