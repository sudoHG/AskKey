import XCTest
import CryptoKit
import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class WorkspaceInteractionTests: WorkspaceVisualContractTestSupport {
    func testEditorInputVisibilityMatchesApprovedInteraction() {
        XCTAssertEqual(
            CredentialEditorInteractionPresentation.inputVisibility(
                template: .custom,
                isSecret: false,
                isRevealed: false
            ),
            .plain
        )
        XCTAssertEqual(
            CredentialEditorInteractionPresentation.inputVisibility(
                template: .api,
                isSecret: true,
                isRevealed: false
            ),
            .secure
        )
        XCTAssertEqual(
            CredentialEditorInteractionPresentation.inputVisibility(
                template: .api,
                isSecret: true,
                isRevealed: true
            ),
            .plain
        )
        XCTAssertEqual(
            CredentialEditorInteractionPresentation.inputVisibility(
                template: .api,
                isSecret: false,
                isRevealed: false
            ),
            .plain
        )
    }

    func testTemplateSecretFieldsMatchTheFrozenPrototype() {
        XCTAssertEqual(CredentialTemplate.api.components.filter(\.isSecret).map(\.name), ["API_KEY"])
        XCTAssertEqual(
            CredentialTemplate.githubApp.components.filter(\.isSecret).map(\.name),
            ["GITHUB_CLIENT_SECRET"]
        )
        XCTAssertTrue(CredentialTemplate.apple.components.filter(\.isSecret).isEmpty)
        XCTAssertEqual(CredentialTemplate.ssh.components.filter(\.isSecret).map(\.name), ["SSH_PASSPHRASE"])
        XCTAssertEqual(
            CredentialTemplate.cloud.components.filter(\.isSecret).map(\.name),
            ["ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "SESSION_TOKEN"]
        )
        XCTAssertEqual(CredentialTemplate.database.components.filter(\.isSecret).map(\.name), ["DB_PASSWORD"])
        XCTAssertTrue(CredentialTemplate.custom.components.filter(\.isSecret).isEmpty)
    }

    func testLockedWorkspaceOffersPendingRequestsWithoutUnlockingManagement() {
        XCTAssertEqual(
            WorkspaceVisualContract.lockedCopy(
                language: "zh-Hans",
                credentialCount: 2,
                pendingRequestCount: 2
            ),
            .init(
                title: "凭证管理已锁定",
                message: "已有 2 份凭证受保护。Agent 请旨不受影响，仍会直接弹出确认框。",
                action: "解锁管理",
                pendingMessage: "有 2 个 Agent 请求等待决定，不需要解锁管理。",
                pendingAction: "直接处理请求"
            )
        )
    }

    func testWelcomeExplainsFingerprintVerification() {
        XCTAssertEqual(
            FrozenWelcomeCopy.agentRequestMessage,
            "请求到达时直接弹出系统确认框，像 Touch ID 一样，点一下加指纹就完成。"
        )
    }

    func testSidebarSelectionFollowsTheVisiblePage() {
        XCTAssertEqual(CredentialWorkspaceRoute.library.sidebarSelection, .credentials)
        XCTAssertEqual(CredentialWorkspaceRoute.pendingRequests.sidebarSelection, .pendingRequests)
        XCTAssertEqual(CredentialWorkspaceRoute.accessRecords.sidebarSelection, .accessRecords)
        XCTAssertEqual(CredentialWorkspaceRoute.agentAccess.sidebarSelection, .agentAccess)
        XCTAssertEqual(CredentialWorkspaceRoute.settings.sidebarSelection, .settings)
        XCTAssertEqual(CredentialWorkspaceRoute.recycleBin.sidebarSelection, .recycleBin)
    }

    func testPendingRequestButtonSelectsItsOwnOperation() {
        let first = pendingApproval(operationID: "first")
        let second = pendingApproval(operationID: "second")
        XCTAssertEqual(
            AgentApprovalRequestSelection.select([first, second], operationID: "second"),
            second
        )
        XCTAssertEqual(
            AgentApprovalRequestSelection.select([first, second], operationID: nil),
            first
        )
    }

    func testTimedAllowanceActionFollowsTheSetting() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(
            FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: true),
            ["仅本次", "允许 30 分钟", "拒绝"]
        )
        XCTAssertEqual(
            FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: false),
            ["仅本次", "拒绝"]
        )
        let writeActions: [(BrokerApprovalOperation, String, String)] = [
            (.create, "批准创建", "Approve Creation"),
            (.modify, "批准修改", "Approve Change"),
            (.delete, "批准删除", "Approve Deletion"),
        ]
        for (operation, chinese, _) in writeActions {
            XCTAssertEqual(FrozenApprovalActions.titles(operation: operation, timedAllowanceEnabled: true),
                           [chinese, "拒绝"])
        }
        AppLanguage.current = "en"
        XCTAssertEqual(FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: true),
                       ["Allow Once", "Allow for 30 Minutes", "Deny"])
        XCTAssertEqual(FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: false),
                       ["Allow Once", "Deny"])
        for (operation, _, english) in writeActions {
            XCTAssertEqual(FrozenApprovalActions.titles(operation: operation, timedAllowanceEnabled: true),
                           [english, "Deny"])
        }
    }

    @MainActor
    func testFrozenSecuritySettingsPersistAcrossRelaunch() {
        let suite = "WorkspaceSecuritySettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let first = makePreviewViewModel(defaults: defaults)
        XCTAssertTrue(first.readApprovalAuthenticationEnabled)
        XCTAssertTrue(first.timedAllowanceEnabled)

        first.readApprovalAuthenticationEnabled = false
        first.timedAllowanceEnabled = false

        let relaunched = makePreviewViewModel(defaults: defaults)
        XCTAssertFalse(relaunched.readApprovalAuthenticationEnabled)
        XCTAssertFalse(relaunched.timedAllowanceEnabled)
    }

}
