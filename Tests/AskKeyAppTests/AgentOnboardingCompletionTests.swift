import Foundation
import XCTest
@testable import AskKeyAppKit

@MainActor
final class AgentOnboardingCompletionTests: AskKeyAppTestCase {
    private var previousLanguage = "en"

    override func setUp() {
        super.setUp()
        previousLanguage = AppLanguage.current
        AppLanguage.current = "en"
    }

    override func tearDown() {
        AppLanguage.current = previousLanguage
        super.tearDown()
    }

    func testPreviousVerifiedResultDoesNotRenderCompletionDuringNewCheck() {
        let session = makeSession(phase: .checking)

        XCTAssertNil(AgentOnboardingCopy.completion(for: .codex, session: session))
    }

    func testPreviousVerifiedResultDoesNotRenderCompletionAfterCurrentFailure() {
        let session = makeSession(phase: .needsAction, failure: .verificationFailed)

        XCTAssertNil(AgentOnboardingCopy.completion(for: .codex, session: session))
    }

    func testPreviousVerifiedResultDoesNotRenderCompletionAfterCancellation() {
        let session = makeSession(phase: .explanation)

        XCTAssertNil(AgentOnboardingCopy.completion(for: .codex, session: session))
    }

    func testVerifiedConnectionUsesConnectedCompletionCopy() throws {
        let session = makeSession(
            phase: .completed,
            result: AgentLastKnownResult(
                outcome: .verifiedConnected,
                checkedAt: Date(timeIntervalSince1970: 2),
                targetSummary: "Codex",
                discovery: .configured
            )
        )

        let completion = try XCTUnwrap(AgentOnboardingCopy.completion(for: .cursor, session: session))
        XCTAssertEqual(completion.title, "Complete: Cursor is connected")
        XCTAssertEqual(
            completion.detail,
            "MCP is connected and credential discovery is configured. Start a new Cursor task to use it."
        )
    }

    func testCodexMCPConnectionAloneDoesNotClaimSetupComplete() {
        XCTAssertNil(AgentOnboardingCopy.completion(for: .codex, session: makeSession(phase: .completed)))
    }

    func testClaudeCompletionRequiresDiscoveryAndExplainsNewSessionInBothLanguages() throws {
        var session = makeSession(phase: .completed)
        XCTAssertNil(AgentOnboardingCopy.completion(for: .claudeCode, session: session))
        session.lastKnownResult?.discovery = .missing
        XCTAssertNil(AgentOnboardingCopy.completion(for: .claudeCode, session: session))
        session.lastKnownResult?.discovery = .configured
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let completion = try XCTUnwrap(AgentOnboardingCopy.completion(for: .claudeCode, session: session))
            if language == "en" {
                XCTAssertEqual(completion.detail, "MCP is connected and the SSH reminder is configured. Start a new Claude Code session to use it.")
            } else {
                XCTAssertTrue(completion.detail.contains("Claude Code"))
                XCTAssertTrue(completion.detail.contains("\u{4F1A}\u{8BDD}"))
                XCTAssertFalse(completion.detail.contains("Start a new"))
            }
        }
    }

    func testCodexCompletionRequiresVerifiedDiscoveryAndExplainsNewTask() throws {
        for readiness in [CredentialDiscoveryReadiness.configured, .missing, .disabled, .untrusted, .unavailable] {
            var session = makeSession(phase: .completed)
            session.lastKnownResult?.discovery = readiness
            XCTAssertNil(AgentOnboardingCopy.completion(for: .codex, session: session))
        }
        var session = makeSession(phase: .completed)
        session.lastKnownResult?.discovery = .enabled
        let completion = try XCTUnwrap(AgentOnboardingCopy.completion(for: .codex, session: session))
        XCTAssertEqual(completion.detail, "MCP is connected and credential discovery before SSH is enabled. Start a new Codex task to use it.")
    }

    func testCursorAndGrokCompletionRequiresConfiguredDiscoveryAndExplainsNewTask() throws {
        for client in [AgentClient.cursor, .grok] {
            for readiness in [CredentialDiscoveryReadiness.missing, .disabled, .untrusted, .unavailable] {
                var session = makeSession(phase: .completed)
                session.lastKnownResult?.discovery = readiness
                XCTAssertNil(
                    AgentOnboardingCopy.completion(for: client, session: session),
                    "\(client.rawValue) must not complete with \(readiness)"
                )
            }

            for readiness in [CredentialDiscoveryReadiness.configured, .enabled] {
                var session = makeSession(phase: .completed)
                session.lastKnownResult?.discovery = readiness
                let completion = try XCTUnwrap(
                    AgentOnboardingCopy.completion(for: client, session: session)
                )
                XCTAssertEqual(
                    completion.title,
                    "Complete: \(client.rawValue) is connected"
                )
                XCTAssertTrue(
                    completion.detail.contains("Start a new \(client.rawValue) task"),
                    completion.detail
                )
            }
        }
    }

    func testDiscoveryStatusCopyIsClientSpecific() {
        XCTAssertTrue(
            AgentOnboardingCopy.discoveryStatus(.configured, for: .codex).contains("Before SSH")
        )
        XCTAssertEqual(
            AgentOnboardingCopy.discoveryStatus(.configured, for: .cursor),
            "Credential discovery is configured"
        )
        XCTAssertEqual(
            AgentOnboardingCopy.discoveryStatus(.enabled, for: .grok),
            "Credential discovery is enabled"
        )
    }

    func testLocalDiscoveryFailureCopyTellsUserToCheckAgain() {
        for client in [AgentClient.cursor, .grok] {
            let message = AgentOnboardingCopy.message(
                for: client,
                failure: .discoverySetupFailed,
                change: .verifiedAndKept
            )
            XCTAssertEqual(
                message,
                "MCP is connected, but credential discovery is not verified. Check again to finish setup."
            )
        }
    }

    private func makeSession(
        phase: AgentOnboardingPhase,
        failure: AgentOnboardingFailure? = nil,
        result: AgentLastKnownResult? = AgentLastKnownResult(
            outcome: .verifiedConnected,
            checkedAt: Date(timeIntervalSince1970: 1),
            targetSummary: "Codex"
        )
    ) -> AgentClientOnboardingSession {
        AgentClientOnboardingSession(
            lastKnownResult: result,
            attempt: AgentOnboardingAttempt(
                phase: phase,
                failure: failure,
                changeStatus: .notWritten,
                message: ""
            ),
            operationID: nil,
            plan: nil
        )
    }
}
