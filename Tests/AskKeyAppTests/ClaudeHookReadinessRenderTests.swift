import AppKit
import SwiftUI
import XCTest
import AskKeyIntegrations
@testable import AskKeyAppKit

/// Render the production Agent access route in a hidden management window.
@MainActor
final class ClaudeHookReadinessRenderTests: AskKeyAppTestCase {
    func testHookRepairMessagesInBothLanguagesThroughTheManagementWindow() async throws {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["en", "zh-Hans"] {
            for disabled in [true, false] {
                let report = try checkReport(disabled: disabled)
                let model = try NoticeLayoutFixtures.Model(
                    language: language, state: .management, recovery: false, broker: false
                )
                defer { model.close() }
                model.vault.onboarding = AgentOnboardingCoordinator(operations: .init(
                    check: { _, _ in report },
                    apply: { _, _, _ in XCTFail("Rendering must not apply settings"); throw AgentOnboardingFailure.cancelled },
                    authenticate: { XCTFail("Rendering must not authenticate"); return .cancelled }
                ))
                await model.vault.onboarding.startCheck(.claudeCode)
                let session = model.vault.onboarding.session(for: .claudeCode)
                let presentation = AgentAccessPresentation(client: .claudeCode, session: session)
                XCTAssertEqual(presentation.status, .needsAttention)
                XCTAssertFalse(presentation.showsConnectedGuide)
                XCTAssertNil(session.plan)
                if disabled {
                    XCTAssertEqual(session.lastKnownResult?.discovery, .disabled)
                    XCTAssertTrue(presentation.headlineIsDiscoveryStatus)
                }
                let expected = expectedMessage(language: language, disabled: disabled)
                XCTAssertEqual(presentation.detail, expected)

                _ = NSApplication.shared
                let window = ManagementWindowConfiguration.makeWindow(rootView:
                    CredentialManagementView(initialRoute: .agentAccess, previewMode: true)
                        .environment(model.vault)
                        .environment(\.locale, model.vault.appLocale)
                        .preferredColorScheme(.light)
                )
                defer { window.close() }
                window.appearance = NSAppearance(named: .aqua)
                let view = try XCTUnwrap(window.contentView)
                for _ in 0..<8 {
                    window.layoutIfNeeded()
                    view.layoutSubtreeIfNeeded()
                    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
                }
                XCTAssertFalse(window.isVisible)
                XCTAssertEqual(window.frame.size, ManagementWindowConfiguration.frameSize)
                let frameView = try XCTUnwrap(view.superview)
                let bitmap = try NoticeLayoutFixtures.render(frameView)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
                try NoticeLayoutFixtures.export(bitmap, name: "claude-hooks-\(disabled ? "disabled" : "customized")-\(language)")
            }
        }
    }

    private func checkReport(disabled: Bool) throws -> AgentCheckReport {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyClaudeRender-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let helper = home.appendingPathComponent("askkey")
        let hook = try CommandDiscoveryClient.claude.configuration(
            home: home, helper: helper, backupDirectory: home.appendingPathComponent("backups")
        )
        var document = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CommandDiscoveryClient.claude.definition(helper: helper)
        ) as? [String: Any])
        if disabled {
            document["disableAllHooks"] = true
        } else {
            var hooks = try XCTUnwrap(document["hooks"] as? [String: [[String: Any]]])
            var group = hooks["PreToolUse"]![0]
            group["matcher"] = "Bash"
            hooks["PreToolUse"] = [group]
            document["hooks"] = hooks
        }
        let settings = CommandDiscoveryClient.claude.hooksURL(home: home)
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = try JSONSerialization.data(withJSONObject: document)
        try bytes.write(to: settings)
        let report = try CommandHookOnboardingSetup.check(
            client: .claudeCode, hook: hook,
            plan: AgentOnboardingPlan(client: .claudeCode, createdAt: .distantPast,
                targetIdentity: "Claude Code", scopeSummary: "", configurationPresent: true,
                verifiesOnly: false, preconditionSummary: ""),
            verifyHelper: {}, hasMCPConfiguration: { true }, isMCPConnected: { true },
            previewMCP: { XCTFail("Existing MCP must be kept") }
        )
        XCTAssertEqual(report.failure, disabled ? .hooksDisabled : .customDiscoveryHook)
        XCTAssertEqual(try Data(contentsOf: settings), bytes)
        return report
    }

    private func expectedMessage(language: String, disabled: Bool) -> String {
        if language == "en" {
            return disabled
                ? "Claude Code hooks are disabled. Re-enable hooks in Claude Code, then check again."
                : "An Ask Key command hook has been customized. Review the hook in your client settings, then check again."
        }
        return disabled
            ? "Claude Code 的钩子已停用。请在 Claude Code 中重新启用钩子，然后再次检查。" // i18n-literal: Assert the Simplified Chinese catalog value.
            : "请旨的命令钩子已被修改。请检查客户端设置中的钩子，然后再次检查。" // i18n-literal: Assert the Simplified Chinese catalog value.
    }
}
