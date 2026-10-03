import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentClientConnectionPolicyTests: AgentClientConnectorTestSupport {
    func testEverySupportedClientUsesAutomaticConnection() {
        XCTAssertTrue(AgentClient.allCases.allSatisfy(\.isAutomatic))
    }

    func testAutomaticClientPreviewsExplainBackupWriteAndVerificationWithoutRawConfig() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        AppLanguage.current = "en"

        for client in [AgentClient.codex, .cursor, .grok] {
            let summary = client.connectionPreviewSummary

            XCTAssertTrue(summary.contains("back up"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("add Ask Key"), "\(client.rawValue): \(summary)")
            XCTAssertTrue(summary.contains("verify"), "\(client.rawValue): \(summary)")
            XCTAssertFalse(summary.contains("--- before"))
            XCTAssertFalse(summary.contains("+++ after"))
            XCTAssertFalse(summary.contains("[skills.config]"))
            XCTAssertFalse(summary.contains("{"))
        }
    }

    func testActiveManagementSessionConnectsWithoutAnotherAuthentication() async {
        var authenticationRequests = 0
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            authenticateDeviceOwner: { _ in
                authenticationRequests += 1
                return .allow
            }
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient { true }

        XCTAssertEqual(connected, true)
        XCTAssertEqual(authenticationRequests, 0)
    }

    func testUnknownCodexVersionDoesNotTellNewerClientsToUpgrade() {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        for language in ["zh-Hans", "en"] {
            AppLanguage.current = language
            let message = AgentClientErrorCopy.message(for: .codex, error: CodexUserMCPError.unknownCodexVersion)
            XCTAssertFalse(message.contains("升级"))
            XCTAssertFalse(message.contains("Update Codex"))
            XCTAssertTrue(message.contains(language == "en" ? "compatibility" : "兼容性"))
        }
    }

    func testClientVerificationFailureUsesOneHumanNextStepWithoutInternalReason() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "AgentClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.grok) {
            throw GrokCLIAdapterError.verificationFailed("helper_signature_internal_401")
        }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "请旨助手的签名或版本不匹配。请重新安装请旨，再重试。"
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("401") == true)
    }

    func testFalseClientVerificationExplainsTheSingleRetryAction() async {
        let previousLanguage = AppLanguage.current
        defer { AppLanguage.current = previousLanguage }
        let suiteName = "FalseClientVerification-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.languageMode = "zh-Hans"
        let viewModel = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            preferences: preferences
        )
        viewModel.isLocked = false
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient(.cursor) { false }

        XCTAssertNil(connected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Cursor 没有完成连接检测。请重启 Cursor，再重试。"
        )
    }

    func testLockedVaultDoesNotWriteClientConfigurationWithAStaleManagementFlag() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.isLocked = true
        viewModel.hasManagementSession = true

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
    }

    func testExpiredManagementSessionDoesNotWriteClientConfiguration() async {
        let connectionAttempts = ConnectionAttemptProbe()
        let viewModel = VaultViewModel(runtimeFileCleanupFailures: { false })
        viewModel.hasManagementSession = false

        let connected = await viewModel.connectAgentClient {
            connectionAttempts.record()
            return true
        }

        XCTAssertNil(connected)
        XCTAssertEqual(connectionAttempts.count, 0)
        XCTAssertEqual(
            viewModel.errorMessage,
            appLocalized("Credential management requires confirmation before it can continue.")
        )
    }
}
