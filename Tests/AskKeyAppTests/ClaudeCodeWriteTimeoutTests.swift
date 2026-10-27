import Foundation
import XCTest
import AskKeyIntegrations
@testable import AskKeyAppKit

@MainActor
final class ClaudeCodeWriteTimeoutTests: AskKeyAppTestCase {
    func testTimeoutReportDiscardsApprovalAndRequiresFreshCheckBeforeAnotherWrite() async {
        for outcome in [ClaudeCodeMCPWriteOutcome.written, .notWritten, .uncertain] {
            let writes = TimeoutWriteCounter()
            let plan = samplePlan()
            let coordinator = AgentOnboardingCoordinator(operations: .init(
                check: { _, _ in
                    AgentCheckReport(outcome: .notConfigured, targetSummary: "Claude Code", plan: plan, failure: nil)
                },
                apply: { _, _, _ in
                    writes.increment()
                    return AgentApplyReport(
                        outcome: outcome == .written ? .configuredUnverified : .notConfigured,
                        changeStatus: AgentChangeStatus(outcome),
                        failure: .claudeWriteTimedOut(outcome), targetSummary: "Claude Code"
                    )
                },
                authenticate: { .confirmed }
            ))
            await coordinator.startCheck(.claudeCode)
            await coordinator.confirm(.claudeCode)
            let session = coordinator.session(for: .claudeCode)
            XCTAssertNil(session.plan)
            XCTAssertEqual(session.attempt.phase, .needsAction)
            XCTAssertEqual(session.attempt.changeStatus, AgentChangeStatus(outcome))
            XCTAssertEqual(session.attempt.failure, .claudeWriteTimedOut(outcome))
            XCTAssertEqual(session.lastKnownResult?.outcome, outcome == .written ? .configuredUnverified : nil)
            XCTAssertNil(AgentOnboardingCopy.completion(for: .claudeCode, session: session))
            XCTAssertFalse(AgentAccessPresentation(client: .claudeCode, session: session).showsConnectedGuide)
            await coordinator.confirm(.claudeCode)
            XCTAssertEqual(writes.count, 1)
            await coordinator.startCheck(.claudeCode)
            XCTAssertEqual(coordinator.session(for: .claudeCode).plan, plan)
            XCTAssertEqual(coordinator.session(for: .claudeCode).attempt.phase, .readyToConfirm)
        }
    }

    func testThrownTimeoutKeepsTheReinspectedOutcome() async {
        for outcome in [ClaudeCodeMCPWriteOutcome.written, .notWritten, .uncertain] {
            let plan = samplePlan()
            var initial = AgentClientOnboardingSession.idle
            initial.plan = plan
            initial.attempt.phase = .readyToConfirm
            initial.lastKnownResult = AgentLastKnownResult(
                outcome: .verifiedConnected, checkedAt: .distantPast, targetSummary: "Claude Code", discovery: .configured
            )
            let coordinator = AgentOnboardingCoordinator(operations: .init(
                check: { _, _ in
                    AgentCheckReport(outcome: .notConfigured, targetSummary: "Claude Code", plan: plan, failure: nil)
                },
                apply: { _, _, _ in throw ClaudeCodeMCPError.writeTimedOut(outcome) },
                authenticate: { .confirmed }
            ), initialSessions: [.claudeCode: initial])
            await coordinator.confirm(.claudeCode)
            let session = coordinator.session(for: .claudeCode)
            XCTAssertEqual(session.attempt.changeStatus, AgentChangeStatus(outcome))
            XCTAssertEqual(session.attempt.failure, .claudeWriteTimedOut(outcome))
            XCTAssertNil(session.plan)
            XCTAssertEqual(session.lastKnownResult?.outcome, outcome == .written ? .configuredUnverified : nil)
            XCTAssertFalse(AgentAccessPresentation(client: .claudeCode, session: session).showsConnectedGuide)
        }
    }

    func testTimeoutCopyDistinguishesEachOutcomeInBothLanguages() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let messages = [ClaudeCodeMCPWriteOutcome.written, .notWritten, .uncertain].map {
                AgentOnboardingCopy.message(for: .claudeCode, failure: .claudeWriteTimedOut($0), change: AgentChangeStatus($0))
            }
            XCTAssertEqual(Set(messages).count, 3)
            let nextStep = language == "en" ? "check again" : "\u{91CD}\u{65B0}\u{68C0}\u{67E5}"
            for message in messages {
                XCTAssertTrue(message.contains("Claude Code"))
                XCTAssertTrue(message.lowercased().contains(nextStep))
            }
            XCTAssertTrue(messages[2].contains("askkey"))
        }
    }

    private func samplePlan() -> AgentOnboardingPlan {
        AgentOnboardingPlan(client: .claudeCode, createdAt: .distantPast, targetIdentity: "Claude Code",
            scopeSummary: "synthetic", configurationPresent: false, verifiesOnly: false, preconditionSummary: "synthetic")
    }
}

private final class TimeoutWriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
