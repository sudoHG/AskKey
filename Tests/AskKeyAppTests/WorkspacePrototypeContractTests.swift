import XCTest
import CryptoKit
import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class WorkspacePrototypeContractTests: WorkspaceVisualContractTestSupport {
    @MainActor
    func testFrozenPrototypePagesRenderAsTaskBuildEvidence() throws {
        let directory = evidenceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let empty = makePreviewViewModel()
        let populated = makePreviewViewModel()
        populated.credentials = [
            credential(id: "prod", name: "生产环境 API", group: "发布"),
            credential(id: "ssh", name: "部署服务器", group: nil),
        ]
        populated.recycledCredentials = [credential(
            id: "old",
            name: "旧数据库账号",
            group: nil,
            deletedAt: Date().addingTimeInterval(-5 * 24 * 60 * 60)
        )]
        populated.storedCredentialGroups = ["发布", "空分组"]
        populated.credentialAccessRecords = [
            .init(
                timestamp: Date(), credentialID: "prod", operation: .runtimeRead,
                result: .allowed, callerHint: "Codex", declaredPurpose: "发布新版本"
            )
        ]
        let request = BrokerApprovalOperationRequest(
            operationID: "preview", credentialID: "prod", targetID: "prod",
            operation: .read, payloadDigest: "redacted", credentialName: "生产环境 API",
            callerName: "Codex", callerPurpose: "发布新版本"
        )
        let secondRequest = BrokerApprovalOperationRequest(
            operationID: "preview-2", credentialID: "ssh", targetID: "ssh",
            operation: .modify, payloadDigest: "redacted", credentialName: "部署服务器",
            callerName: "Cursor", callerPurpose: "更新服务器地址"
        )

        try render(SettingsView().environment(empty), as: "01-welcome", in: directory)
        try render(
            FirstRunOnboardingView(
                onCreateCredential: {},
                onImportCredential: {},
                initialLaunchAtLoginEnabled: false
            ).environment(empty),
            as: "01b-welcome-login-off", in: directory
        )
        let locked = makePreviewViewModel()
        locked.hasCompletedOnboarding = true
        locked.isLocked = true
        locked.onboardingCredentialCount = 2
        locked.pendingApprovalCount = 2
        try render(SettingsView().environment(locked), as: "02-locked", in: directory)
        try render(manager(empty), as: "03-library-empty", in: directory)
        try render(manager(populated), as: "04-library-list", in: directory)
        try render(manager(populated, section: .ungrouped), as: "05-ungrouped", in: directory)
        try render(manager(populated, section: .named("发布")), as: "06-group-list", in: directory)
        try render(manager(populated, section: .named("空分组")), as: "07-group-empty", in: directory)
        try render(manager(empty, section: .recycleBin, route: .recycleBin), as: "08-bin-empty", in: directory)
        try render(manager(populated, section: .recycleBin, route: .recycleBin), as: "09-bin-content", in: directory)
        try render(manager(empty, route: .pendingRequests), as: "10-requests-empty", in: directory)
        populated.pendingApprovalCount = 2
        try render(
            manager(
                populated,
                route: .pendingRequests,
                pendingRequests: [request, secondRequest]
            ),
            as: "11-requests-content", in: directory
        )
        try render(manager(populated, section: .accessRecords, route: .accessRecords), as: "12-records", in: directory)
        try render(manager(populated, section: .agentAccess, route: .agentAccess), as: "13-agent-access", in: directory)
        try render(manager(populated, route: .templateChooser), as: "14-template-chooser", in: directory)
        try render(
            manager(populated, route: .editor(template: .custom, credentialID: nil)),
            as: "15-editor-collapsed", in: directory
        )
        try render(
            manager(
                populated,
                route: .editor(template: .custom, credentialID: nil),
                editorExpanded: true
            ),
            as: "15b-editor-expanded", in: directory
        )
        let saved = makePreviewViewModel()
        saved.credentials = [credential(id: "saved", name: "新建的自定义凭证", group: nil)]
        try render(manager(saved), as: "15c-editor-save-result", in: directory)
        try render(manager(populated, route: .fileImport), as: "16-import-empty", in: directory)
        try render(
            manager(
                populated,
                route: .fileImport,
                importValues: [("API_KEY", "redacted"), ("API_ENDPOINT", "https://api.example.com")]
            ),
            as: "16b-import-preview", in: directory
        )
        let imported = makePreviewViewModel()
        imported.credentials = [credential(id: "imported", name: "导入的环境变量", group: nil)]
        try render(manager(imported), as: "16c-import-result", in: directory)
        try render(manager(populated, route: .credentialDetail("prod"), selectedID: "prod"), as: "17-detail", in: directory)
        try render(
            manager(
                populated, route: .credentialDetail("prod"), selectedID: "prod",
                credentialDeleteConfirmation: "prod"
            ),
            as: "17a-detail-delete-confirmation", in: directory
        )
        try render(
            manager(populated, route: .editor(template: .api, credentialID: "prod")),
            as: "17b-detail-edit", in: directory
        )
        let deleted = makePreviewViewModel()
        deleted.recycledCredentials = [credential(
            id: "deleted", name: "生产环境 API", group: "发布",
            deletedAt: Date().addingTimeInterval(-5 * 24 * 60 * 60)
        )]
        try render(
            manager(deleted, section: .recycleBin, route: .recycleBin),
            as: "17c-detail-delete-result", in: directory
        )
        try render(
            manager(populated, route: .settings),
            as: "18-settings", in: directory
        )
        try render(
            manager(
                populated,
                route: .settings,
                readAuthenticationConfirmation: true
            ),
            as: "18b-settings-read-warning", in: directory
        )
        try render(
            manager(
                populated,
                route: .settings,
                settingsErase: true
            ),
            as: "18d-settings-erase-empty", in: directory
        )
        try render(
            manager(populated, section: .named("发布"), groupDeleteConfirmation: "发布"),
            as: "18e-group-delete-confirmation", in: directory
        )
        try render(
            manager(populated, route: .settings, accessRecordClearConfirmation: true),
            as: "18f-records-clear-confirmation", in: directory
        )
        try render(
            FrozenAgentApprovalPrompt(
                request: request,
                expiresAt: Date().addingTimeInterval(299),
                timedAllowanceEnabled: true,
                finish: { _ in }
            ),
            as: "19-agent-approval", in: directory, size: .init(width: 360, height: 430)
        )
        try render(
            FrozenAgentApprovalPrompt(
                request: request,
                expiresAt: Date().addingTimeInterval(299),
                timedAllowanceEnabled: false,
                finish: { _ in }
            ),
            as: "19b-agent-approval-timed-disabled", in: directory,
            size: .init(width: 360, height: 360)
        )
        let menuRunning = makePreviewViewModel()
        menuRunning.pendingApprovalCount = 1
        try render(
            VaultPopover(onOpenManagement: {}).environment(menuRunning),
            as: "20-menu-running", in: directory,
            size: .init(width: 280, height: 160)
        )
        let pausedDefaults = UserDefaults(suiteName: "331-382-menu-paused-\(UUID().uuidString)") ?? .standard
        pausedDefaults.set("zh-Hans", forKey: "languageMode")
        pausedDefaults.set("light", forKey: "appearanceMode")
        let menuPaused = VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: pausedDefaults),
            loginItem: LoginItemController(isEnabled: { true }, setEnabled: { _ in }),
            isAgentAccessPaused: { true },
            credentialMutations: .readOnly { ([], [], [], false) }
        )
        menuPaused.hasManagementSession = false
        menuPaused.isLocked = true
        try render(
            VaultPopover(onOpenManagement: {}).environment(menuPaused),
            as: "20b-menu-paused", in: directory,
            size: .init(width: 280, height: 160)
        )

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.first?.isNumber == true && $0.hasSuffix(".png") }.count,
            34
        )
    }

    func testFrozenPrototypeUsesChineseTemplateCardsAndThreePermissionSegments() {
        XCTAssertEqual(
            CredentialTemplate.allCases.map(\.prototypeTitle),
            [
                "API 访问凭证",
                "GitHub 应用",
                "Apple 发布签名",
                "SSH 登录身份",
                "云服务账号",
                "数据库或服务连接",
                "自定义凭证",
            ]
        )
        XCTAssertEqual(
            CredentialPermission.prototypeCases.map(\.prototypeTitle),
            ["每次询问（推荐）", "允许", "隐藏"]
        )
    }

    func testFrozenPrototypeWorkflowsStayInsideTheMainWindow() {
        XCTAssertNotEqual(CredentialWorkspaceRoute.templateChooser, .fileImport)
        XCTAssertNotEqual(CredentialWorkspaceRoute.settings, .pendingRequests)
        XCTAssertNotEqual(
            CredentialWorkspaceRoute.editor(template: .custom, credentialID: nil),
            .templateChooser
        )
    }

    func testFrozenPrototypeWorkspaceMetricsAndCopy() {
        XCTAssertEqual(WorkspaceVisualContract.windowWidth, 980)
        XCTAssertEqual(WorkspaceVisualContract.windowHeight, 620)
        XCTAssertEqual(WorkspaceVisualContract.sidebarWidth, 204)
        XCTAssertEqual(WorkspaceVisualContract.windowBackgroundHex, "F6F6F4")
        XCTAssertEqual(
            WorkspaceVisualContract.welcomeCopy(language: "zh-Hans"),
            .init(
                title: "欢迎使用请旨",
                message: "把一整套凭证材料放在一起。Agent 需要时，系统确认框会直接问你，由你当场决定。",
                createAction: "创建凭证",
                importAction: "从文件导入"
            )
        )
        XCTAssertEqual(
            WorkspaceVisualContract.lockedCopy(language: "zh-Hans", credentialCount: 2),
            .init(
                title: "凭证管理已锁定",
                message: "已有 2 份凭证受保护。Agent 的请求不受影响，照常会弹窗问你。",
                action: "解锁管理"
            )
        )
    }

    func testFrozenPrototypeHasCompleteEnglishWorkspaceCopy() {
        XCTAssertEqual(
            WorkspaceVisualContract.welcomeCopy(language: "en"),
            .init(
                title: "Welcome to Ask Key",
                message: "Keep a complete set of credential materials together. When an Agent needs them, a system confirmation asks you to decide.",
                createAction: "Create Credential",
                importAction: "Import from File"
            )
        )
        XCTAssertEqual(
            WorkspaceVisualContract.lockedCopy(language: "en", credentialCount: 1),
            .init(
                title: "Credential Management is Locked",
                message: "1 credential is protected. Agent requests are not affected and still ask you.",
                action: "Unlock Management"
            )
        )
    }

    func testEnglishWorkspaceSurfacesContainNoChineseCopy() {
        AppLanguage.current = "en"
        defer { AppLanguage.current = "zh-Hans" }
        let conflict = FrozenImportConflictPresentation(existingName: "Existing", choice: .replace)
        let strings = CredentialTemplate.allCases.flatMap { [$0.prototypeTitle, $0.prototypeDescription, $0.editorTitle] }
            + CredentialPermission.prototypeCases.flatMap { [$0.prototypeTitle, $0.editorTitle, $0.editorExplanation] }
            + [FrozenImportCopy.nameHelp, FrozenImportCopy.contentsHeader, FrozenEditorCopy.contentHiddenLabel]
            + FrozenSettingsContract.languageOptions
            + [FrozenSettingsContract.agentAccessSubtitle]
            + FrozenDangerActions.initialTitles
            + FrozenDangerActions.confirmationTitles
            + FrozenCollectionCopy.groupActions
            + [
                FrozenCredentialDetailCopy.protectionTitle,
                FrozenCredentialDetailCopy.protectionMessage,
                FrozenCollectionCopy.groupSubtitle,
                FrozenCollectionCopy.recycleSubtitle,
                FrozenCollectionCopy.recycleEmptyMessage,
                FrozenAccessRecordsCopy.subtitle,
                FrozenEditorCopy.customHelp,
                FrozenEditorMoreSettingsPresentation.expiryHelp,
                conflict.warning ?? "",
                conflict.confirmTitle,
            ]
        XCTAssertNil(
            strings.joined(separator: " ").range(
                of: "[\\u{4E00}-\\u{9FFF}]",
                options: .regularExpression
            )
        )
    }

    func testChineseWorkspaceActionsDoNotFallBackToEnglish() {
        XCTAssertEqual(
            AppLanguage.localized("Clear all access records?", language: "zh-Hans"),
            "清空所有访问记录？"
        )
        XCTAssertEqual(
            AppLanguage.localized("No ungrouped credentials", language: "zh-Hans"),
            "没有未分组凭证"
        )
        XCTAssertEqual(
            AppLanguage.localized(
                "All credentials are grouped, or there are no credentials yet.",
                language: "zh-Hans"
            ),
            "所有凭证都已有分组，或还没有凭证。"
        )
        for error in [
            "The .env file contains no key-value pairs.",
            "AskKey only imports ordinary files. Symbolic links are not allowed.",
            "AskKey only imports ordinary files. Directories are not allowed.",
            "AskKey only imports ordinary files. Special files are not allowed.",
            "This file is larger than AskKey's 5 MB import limit.",
            "The file changed while AskKey was reading it. Import was cancelled.",
            "Choose an ordinary file before saving this credential.",
            "Stored file bytes do not match the saved digest.",
            "The file could not be read.",
        ] {
            XCTAssertNotEqual(AppLanguage.localized(error, language: "zh-Hans"), error)
        }
    }

}
