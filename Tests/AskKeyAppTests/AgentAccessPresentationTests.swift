import Foundation
import XCTest
import AskKeyIntegrations
@testable import AskKeyAppKit

@MainActor
final class AgentAccessPresentationTests: AskKeyAppTestCase {
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

    func testFirstVisitIsNotCheckedAndOffersToConnect() {
        let presentation = AgentAccessPresentation(client: .claudeCode, session: .idle)

        XCTAssertEqual(presentation.status, .notChecked)
        XCTAssertEqual(presentation.status.role, .neutral)
        XCTAssertEqual(presentation.actionTitle(expanded: false), "Connect…")
        XCTAssertEqual(presentation.actionTitle(expanded: true), "Collapse")
        XCTAssertEqual(presentation.currentStep, .check)
        XCTAssertEqual(presentation.headline, "Check whether Claude Code is on this Mac")
        XCTAssertFalse(presentation.showsConnectedGuide)
    }

    func testMissingClientIsNotFoundWithInstallAdvice() {
        let presentation = AgentAccessPresentation(
            client: .codex,
            session: session(phase: .needsAction, failure: .cliMissing, result: nil)
        )

        XCTAssertEqual(presentation.status, .notFound)
        XCTAssertEqual(presentation.status.role, .neutral)
        XCTAssertEqual(presentation.headline, "Codex was not found on this Mac")
        XCTAssertTrue(presentation.detail.hasPrefix("Install or open Codex, then check again."))
        XCTAssertEqual(presentation.stepState(.check), .current)
        XCTAssertEqual(presentation.stepState(.confirm), .upcoming)
    }

    func testConnectedClientShowsGuideAndEveryStepDone() {
        let presentation = AgentAccessPresentation(
            client: .claudeCode,
            session: session(phase: .completed, result: verified(.configured))
        )

        XCTAssertEqual(presentation.status, .connected)
        XCTAssertEqual(presentation.status.role, .accent)
        XCTAssertNil(presentation.currentStep)
        XCTAssertEqual(AgentAccessStep.allCases.map(presentation.stepState), [.done, .done, .done])
        XCTAssertEqual(presentation.headline, "Claude Code is connected")
        XCTAssertTrue(presentation.showsConnectedGuide)
        XCTAssertEqual(presentation.actionTitle(expanded: false), "Show details")
    }

    func testConnectedStatusSurvivesCollapseButGuideNeedsCompletedCheck() {
        let presentation = AgentAccessPresentation(
            client: .cursor,
            session: session(phase: .explanation, result: verified(.configured))
        )

        XCTAssertEqual(presentation.status, .connected)
        XCTAssertFalse(presentation.showsConnectedGuide)
    }

    func testMissingDiscoveryNeedsAttentionAndLeadsWithDiscoveryStatus() {
        let codex = AgentAccessPresentation(
            client: .codex,
            session: session(phase: .completed, result: verified(.configured))
        )
        XCTAssertEqual(codex.status, .needsAttention)
        XCTAssertEqual(codex.status.role, .warning)
        XCTAssertTrue(codex.headlineIsDiscoveryStatus)
        XCTAssertEqual(codex.headline, "Before SSH: credential discovery configured")
        XCTAssertEqual(codex.actionTitle(expanded: false), "Review")
        XCTAssertFalse(codex.showsConnectedGuide)

        let grok = AgentAccessPresentation(
            client: .grok,
            session: session(phase: .needsAction, failure: .discoverySetupFailed, result: verified(.missing))
        )
        XCTAssertEqual(grok.headline, "Credential discovery is not installed")
        XCTAssertEqual(
            grok.detail,
            "MCP is connected, but credential discovery is not verified. Check again to finish setup."
        )
    }

    func testFailedCheckNeedsAttentionWithItsMessage() {
        let presentation = AgentAccessPresentation(
            client: .codex,
            session: session(phase: .needsAction, failure: .verificationFailed, result: nil)
        )

        XCTAssertEqual(presentation.status, .needsAttention)
        XCTAssertEqual(presentation.headline, "Codex needs attention")
        XCTAssertEqual(
            presentation.detail,
            "Existing configuration is present, but this verification did not pass. Nothing was changed."
        )
        XCTAssertFalse(presentation.offersIssueLink)
    }

    func testPlanAwaitingConfirmationIsTheSecondStep() {
        var pending = session(
            phase: .readyToConfirm,
            result: AgentLastKnownResult(outcome: .notConfigured, checkedAt: .distantPast, targetSummary: "Cursor")
        )
        pending.plan = AgentOnboardingPlan(
            client: .cursor,
            createdAt: .distantPast,
            targetIdentity: "Cursor",
            scopeSummary: "Synthetic scope",
            configurationPresent: false,
            verifiesOnly: false,
            preconditionSummary: "Synthetic precondition"
        )
        let presentation = AgentAccessPresentation(client: .cursor, session: pending)

        XCTAssertEqual(presentation.status, .notConnected)
        XCTAssertEqual(AgentAccessStep.allCases.map(presentation.stepState), [.done, .current, .upcoming])
        XCTAssertEqual(presentation.headline, "Confirm the changes to Cursor")
        XCTAssertEqual(presentation.detail, "Synthetic scope")
    }

    func testFailedRestoreOffersRecoveryNotesAndIssueLink() {
        var locked = session(phase: .recoveryRequired, failure: .restoreFailed, result: nil)
        locked.attempt.changeStatus = .restoreFailed
        let presentation = AgentAccessPresentation(client: .grok, session: locked)

        XCTAssertEqual(presentation.status, .needsAttention)
        XCTAssertEqual(presentation.currentStep, .verify)
        XCTAssertTrue(presentation.offersRecoveryNotes)
        XCTAssertTrue(presentation.offersIssueLink)
        XCTAssertEqual(AgentOnboardingCopy.issuesURL.absoluteString, "https://github.com/sudoHG/AskKey/issues")

        let unsupported = AgentAccessPresentation(
            client: .codex,
            session: session(phase: .needsAction, failure: .unsupportedVersion, result: nil)
        )
        XCTAssertTrue(unsupported.offersIssueLink)
        XCTAssertFalse(unsupported.offersRecoveryNotes)
    }

    func testRecoveryCopyIsSelfContainedAndNeverSaysContactSupport() {
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let notes = AgentOnboardingCopy.recoveryNotes(for: .cursor)
            XCTAssertTrue(notes.contains("client-backups"), notes)
            XCTAssertTrue(notes.contains("GitHub Issues"), notes)
            XCTAssertEqual(notes.components(separatedBy: "Cursor").count - 1, 2, notes)
            for error in [CodexUserMCPError.rollbackFailed, .unknownCodexVersion] {
                let message = AgentClientErrorCopy.message(for: .codex, error: error)
                XCTAssertTrue(message.contains("github.com/sudoHG/AskKey/issues"), message)
                XCTAssertFalse(message.localizedCaseInsensitiveContains("contact support"), message)
                XCTAssertFalse(message.contains("联系支持"), message) // i18n-literal: Assert the Simplified Chinese catalog value.
            }
        }
    }

    func testSamplePromptAndSSHNoteInBothLanguages() {
        XCTAssertEqual(
            AgentOnboardingCopy.samplePrompt(credentialName: "demo-api").plainText,
            "Use demo-api from Ask Key to run ./deploy.sh --env staging"
        )
        XCTAssertEqual(
            AgentOnboardingCopy.samplePrompt(credentialName: nil).plainText,
            "Find the right credential in Ask Key and run ./deploy.sh --env staging"
        )
        XCTAssertTrue(AgentOnboardingCopy.sshReminderNote.plainText.contains("never authorizes"))

        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(
            AgentOnboardingCopy.samplePrompt(credentialName: "demo-api").plainText,
            "用请旨里的 demo-api 跑一下 ./deploy.sh --env staging" // i18n-literal: Assert the Simplified Chinese catalog value.
        )
        XCTAssertEqual(
            AgentOnboardingCopy.sshReminderNote.plainText,
            "SSH 前提醒已开启：Agent 运行 ssh 前，会先被提醒查一下请旨。只是提醒，不会自动授权。" // i18n-literal: Assert the Simplified Chinese catalog value.
        )
        XCTAssertEqual(AgentAccessStatus.connected.title, "已接入") // i18n-literal: Assert the Simplified Chinese catalog value.
        XCTAssertEqual(AgentAccessStatus.notChecked.title, "未检查") // i18n-literal: Assert the Simplified Chinese catalog value.
        XCTAssertEqual(AgentAccessStatus.needsAttention.title, "需要处理") // i18n-literal: Assert the Simplified Chinese catalog value.
    }

    private func verified(_ discovery: CredentialDiscoveryReadiness) -> AgentLastKnownResult {
        AgentLastKnownResult(
            outcome: .verifiedConnected,
            checkedAt: .distantPast,
            targetSummary: "synthetic",
            discovery: discovery
        )
    }

    private func session(
        phase: AgentOnboardingPhase,
        failure: AgentOnboardingFailure? = nil,
        result: AgentLastKnownResult?
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
