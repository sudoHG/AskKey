import XCTest
import CryptoKit
import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyVault
@testable import AskKeyAppKit

final class WorkspaceVisualContractTests: AskKeyAppTestCase {
    override func setUp() {
        super.setUp()
        AppLanguage.current = "zh-Hans"
    }

    @MainActor
    func testManagementWindowAppliesTheFrozenFrameAndKeepsFunctionalSystemTrafficLights() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "请旨"

        ManagementWindowConfiguration.apply(to: window)

        XCTAssertEqual(window.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, 620, accuracy: 2)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 980, height: 620))
        XCTAssertEqual(window.contentMaxSize, NSSize(width: 980, height: 620))
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))
        XCTAssertEqual(window.title, "请旨")
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)

        let beforeZoom = window.frame
        window.zoom(nil)
        XCTAssertEqual(window.frame.size.width, beforeZoom.size.width, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, beforeZoom.size.height, accuracy: 2)
    }

    @MainActor
    func testManagementWindowStaysFrozenAfterSwiftUIContentSizeLayout() {
        _ = NSApplication.shared
        let viewModel = makePreviewViewModel()
        viewModel.hasCompletedOnboarding = true
        let window = ManagementWindowConfiguration.makeWindow(
            rootView: SettingsView()
                .environment(viewModel)
                .frame(
                    width: WorkspaceVisualContract.windowWidth,
                    height: WorkspaceVisualContract.windowHeight
                )
        )
        window.title = "请旨"

        let observers = ManagementWindowConfiguration.installObservers()
        defer {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        var restoredOversizedFrame = false
        let watchResizes: (NSWindow) -> NSObjectProtocol = { target in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: target,
                queue: nil
            ) { note in
                guard let resized = note.object as? NSWindow else { return }
                if resized.frame.height > WorkspaceVisualContract.windowHeight + 2 {
                    restoredOversizedFrame = true
                }
            }
        }
        let resizeWatcher = watchResizes(window)
        defer { NotificationCenter.default.removeObserver(resizeWatcher) }

        window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        restoredOversizedFrame = false
        pumpWindowLayout(window)
        window.setContentSize(ManagementWindowConfiguration.frameSize)
        window.contentView?.invalidateIntrinsicContentSize()
        window.contentView?.needsLayout = true
        pumpWindowLayout(window)

        XCTAssertFalse(
            restoredOversizedFrame,
            "SwiftUI content-size layout restored a 652pt outer frame"
        )
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertEqual(window.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, 620, accuracy: 2)
        XCTAssertEqual(window.contentView?.frame.origin.x ?? -1, 0, accuracy: 2)
        XCTAssertEqual(window.title, "请旨")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.miniaturizeButton)?.isHidden, false)
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)
        XCTAssertFalse(window.styleMask.contains(.resizable))
        let beforeZoom = window.frame
        window.zoom(nil)
        XCTAssertEqual(window.frame.size.width, beforeZoom.size.width, accuracy: 2)
        XCTAssertEqual(window.frame.size.height, beforeZoom.size.height, accuracy: 2)

        let oversized = makeSwiftUILikeManagementWindow(viewModel: viewModel)
        XCTAssertGreaterThan(oversized.frame.height, WorkspaceVisualContract.windowHeight + 2)
        let oversizedWatcher = watchResizes(oversized)
        defer {
            NotificationCenter.default.removeObserver(oversizedWatcher)
            oversized.close()
        }
        restoredOversizedFrame = false
        ManagementWindowConfiguration.apply(to: oversized)
        oversized.makeKeyAndOrderFront(nil)
        pumpWindowLayout(oversized)
        oversized.setContentSize(ManagementWindowConfiguration.frameSize)
        oversized.contentView?.invalidateIntrinsicContentSize()
        pumpWindowLayout(oversized)
        XCTAssertFalse(restoredOversizedFrame)
        XCTAssertTrue(oversized.canBecomeKey)
        XCTAssertEqual(oversized.frame.size.width, 980, accuracy: 2)
        XCTAssertEqual(oversized.frame.size.height, 620, accuracy: 2)
        window.close()
    }

    func testCustomEditorUsesFrozenKeyValueTableCopy() {
        XCTAssertEqual(FrozenEditorCopy.tableHeaders, ["键", "值"])
        XCTAssertEqual(
            FrozenEditorCopy.customHelp,
            "像 .env 一样填写键和值；每行的值可以是普通文字或文件。"
        )
        XCTAssertEqual(FrozenEditorCopy.customAddActions, ["添加文字键", "添加文件键"])
        XCTAssertEqual(
            FrozenEditorCopy.kindLabel(for: .text),
            "文字"
        )
        XCTAssertEqual(FrozenEditorCopy.kindLabel(for: .file), "文件")
    }

    func testGroupHeaderAndSearchFollowFrozenScope() {
        XCTAssertEqual(
            FrozenCollectionCopy.groupActions,
            ["从文件导入", "新建凭证到本组", "删除分组…"]
        )
        XCTAssertTrue(FrozenCollectionCopy.showsSearch(section: .all, hasCredentials: true))
        XCTAssertFalse(FrozenCollectionCopy.showsSearch(section: .named("发布"), hasCredentials: true))
        XCTAssertFalse(FrozenCollectionCopy.showsSearch(section: .all, hasCredentials: false))
    }

    func testDangerActionsAndRecycleCredentialMarkerStartVisible() {
        XCTAssertEqual(
            FrozenDangerActions.initialTitles,
            ["删除分组…", "永久删除…", "删除…", "暂停 Agent 访问", "清空记录…"]
        )
        XCTAssertEqual(RecycleBinPresentation.credentialMarker(name: "旧数据库账号"), "旧")
        XCTAssertEqual(RecycleBinPresentation.credentialMarker(name: ""), "凭")
        XCTAssertEqual(
            FrozenDangerActions.confirmationTitles,
            ["确认删除分组", "移到回收站", "确认清空"]
        )
    }

    func testRecordsSubtitleAndProductionPendingPageHasNoSimulationActions() {
        XCTAssertEqual(
            FrozenAccessRecordsCopy.subtitle,
            "保留最近 90 天；只记录谁请求了什么、结果如何，永远不记录凭证内容。可在「设置」里手动清空。"
        )
        XCTAssertTrue(FrozenPendingRequestsCopy.simulationActions.isEmpty)
    }

    func testChangingCredentialGroupClearsSearchAndSearchMissHasHonestEmptyCopy() {
        XCTAssertEqual(
            CredentialSearchPresentation.queryAfterChangingSection("production"),
            ""
        )
        XCTAssertEqual(
            CredentialEmptyPresentation.title(section: .all, searchText: "missing"),
            "没有找到匹配的凭证"
        )
        XCTAssertEqual(
            CredentialEmptyPresentation.message(section: .all, searchText: "missing"),
            "换个关键词再试试。"
        )
        XCTAssertNil(CredentialEmptyPresentation.action(section: .all, searchText: "missing"))
    }

    func testPermanentDeleteHasAnInAppConfirmationBeforeAuthentication() {
        XCTAssertEqual(FrozenDangerActions.permanentCredentialConfirmationTitle, "确认永久删除")
    }

    func testDetailKeepsPlaintextProtectionAndFieldKindsVisibleBeforeReveal() {
        XCTAssertEqual(FrozenCredentialDetailCopy.protectionTitle, "明文保护")
        XCTAssertEqual(
            FrozenCredentialDetailCopy.protectionMessage,
            "即使管理已解锁，查看或复制明文都要再次验证身份；复制的内容 60 秒后自动从剪贴板清除。"
        )
        XCTAssertEqual(FrozenCredentialDetailCopy.kindLabel(componentName: "API_KEY"), "已保护")
        XCTAssertEqual(FrozenCredentialDetailCopy.kindLabel(componentName: "API_ENDPOINT"), "文字")
        XCTAssertEqual(FrozenCredentialDetailCopy.kindLabel(componentName: "BASE_URL"), "文字")
        XCTAssertEqual(
            FrozenCredentialDetailCopy.kindLabel(componentName: "CUSTOM_FILE", kind: .file),
            "文件"
        )
    }

    func testWelcomeAndImportPreviewUseFrozenExplanations() {
        XCTAssertEqual(
            FrozenWelcomeCopy.backgroundMessage,
            "登录时启动默认开启；未运行时 Agent 无法取得凭证。"
        )
        XCTAssertEqual(FrozenWelcomeCopy.launchAtLoginSubtitle, "让 Agent 随时能找到请旨")
        XCTAssertEqual(
            FrozenImportCopy.previewSummary(itemCount: 2, skippedLineCount: 1),
            "包含 2 项；跳过空行 1 行。"
        )
        XCTAssertEqual(FrozenImportTableLayout.columnWeights, [1, 1.4])
    }

    func testFrozenCredentialListUsesTemplateItemPermissionAndGroupTags() {
        let presentation = CredentialListPresentation(
            credential: credential(id: "api", name: "生产环境 API", group: "发布")
        )
        XCTAssertEqual(
            presentation.tags,
            ["API 访问凭证", "2 项内容", "每次使用前问我（推荐）", "发布"]
        )
        XCTAssertEqual(
            CredentialListPresentation(
                credential: credential(id: "ssh", name: "部署服务器", group: nil)
            ).tags,
            ["SSH 登录身份", "1 项内容", "每次使用前问我（推荐）", "未分组"]
        )
    }

    func testFrozenSettingsAndNavigationCopyStayExact() {
        XCTAssertEqual(
            FrozenReadAuthenticationPresentation(enabled: true, confirmingDisable: false),
            .init(actionTitle: "关闭…", warning: nil, confirmationTitle: nil)
        )
        XCTAssertEqual(
            FrozenReadAuthenticationPresentation(enabled: true, confirmingDisable: true),
            .init(
                actionTitle: "关闭…",
                warning: "关闭后，Agent 的读取请求点一下就放行，不再确认是不是你本人。修改凭证始终需要验证，不受影响。",
                confirmationTitle: "仍要关闭"
            )
        )
        XCTAssertEqual(FrozenSettingsContract.languageOptions, ["跟随系统", "中文", "English"])
        XCTAssertEqual(FrozenSettingsContract.agentAccessSubtitle, "选择你要使用的客户端。查看接入方式后，再决定是否检查或配置。")
        AppLanguage.current = "en"
        XCTAssertEqual(
            FrozenSettingsContract.agentAccessSubtitle,
            "Choose a client. Review how it connects, then decide whether to check or configure."
        )
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(FrozenSettingsContract.emptyLibraryAction, "新建第一份凭证")
    }

    func testLoginAtStartupTurnsOffInlineWithFrozenWarning() {
        XCTAssertEqual(
            FrozenLoginAtStartupPresentation(isEnabled: false),
            .init(
                isEnabled: false,
                warning: "关闭后，重启 Mac 请旨不会自己运行，Agent 将取不到任何凭证。"
            )
        )
        XCTAssertNil(FrozenLoginAtStartupPresentation(isEnabled: true).warning)
        XCTAssertNil(
            FrozenLoginAtStartupPresentation(
                isEnabled: false,
                showsWarning: false
            ).warning
        )
    }

    func testImportPreviewShowsValuesAndResolvesNameConflictInline() {
        XCTAssertTrue(FrozenImportConflictPresentation.showsValues)
        XCTAssertEqual(
            FrozenImportConflictPresentation(existingName: "导入的环境变量", choice: .skip),
            .init(
                warning: "已存在同名凭证「导入的环境变量」。请选择整份凭证的处理方式：跳过这份，或验证身份后用导入内容替换现有内容。",
                choices: ["跳过这份", "验证后替换现有"],
                selectedChoice: .skip,
                confirmTitle: "跳过并完成"
            )
        )
        XCTAssertEqual(
            FrozenImportConflictPresentation(existingName: "导入的环境变量", choice: .replace).confirmTitle,
            "确认导入"
        )
        XCTAssertNil(FrozenImportConflictPresentation(existingName: nil, choice: .skip).warning)
    }

    func testOrdinaryFileImportUsesStableComponentNameAndLocalizedDisplay() throws {
        let frozen = try FileImport.FrozenFile(
            originalFilename: "certificate.pem",
            bytes: Data("certificate".utf8)
        )

        let component = FrozenFileImportMapping.component(from: frozen)

        XCTAssertEqual(component.name, "FILE")
        AppLanguage.current = "en"
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: component.name), "File")
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "文件"), "File")
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: component.name), "文件")
    }

    func testImportReplacementPreservesExistingCredentialMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportReplacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VaultStore(path: root.appendingPathComponent("synthetic.db").path)
        defer { try? store.close() }
        let vault = Vault(store: store, key: SymmetricKey(size: .bits256), fileDeliveryManager: try FileDeliveryManager(rootURL: root.appendingPathComponent("deliveries")))
        try vault.beginManagementSession(using: .allow)
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let original = try vault.createBundleCredential(.init(
            name: "Production API", components: [.init(name: "API_KEY", value: .text("old"))],
            usageInstructions: "Release only", privateNotes: "Private owner note", groupName: "Release", permission: .allowed, expiresAt: expiry
        ), using: .allow)
        let existing = try XCTUnwrap(vault.listTextCredentials().first)
        XCTAssertNil(existing.privateNotes)
        let imported = [CredentialComponentInput(name: "API_KEY", value: .text("new"))]
        _ = try vault.replaceImportedBundleCredential(id: existing.id, components: imported, using: .allow)
        let result = try vault.revealTextCredential(id: original.id, using: .allow)
        XCTAssertEqual(result.privateNotes, "Private owner note")
        XCTAssertEqual(result.name, original.name)
        XCTAssertEqual(result.usageInstructions, original.usageInstructions)
        XCTAssertEqual(result.groupName, original.groupName)
        XCTAssertEqual(result.permission, original.permission)
        XCTAssertEqual(result.expiresAt, original.expiresAt)
        XCTAssertEqual(result.components.first?.value, .text("new"))
    }

    func testMoreSettingsMatchTheFrozenThreeFieldsAndOptionalDate() {
        XCTAssertEqual(
            FrozenEditorMoreSettingsPresentation.labels,
            ["给 Agent 的说明（可选）", "私人备注（可选）", "到期时间（可选）"]
        )
        XCTAssertEqual(
            FrozenEditorMoreSettingsPresentation.expiryHelp,
            "到期后凭证自动停用：Agent 请求被自动拒绝，到期前 7 天开始提醒。"
        )
        XCTAssertNotNil(FrozenEditorMoreSettingsPresentation.expiryDate(from: "2026-09-30"))
        XCTAssertNil(FrozenEditorMoreSettingsPresentation.expiryDate(from: "2026-02-30"))
        XCTAssertNil(FrozenEditorMoreSettingsPresentation.expiryDate(from: ""))
    }

    func testGroupAndRecycleBinCopyStayComplete() {
        XCTAssertEqual(
            FrozenCollectionCopy.groupSubtitle,
            "分组只是整理方式，不影响授权边界；在这里新建的凭证会直接落进本组。"
        )
        XCTAssertEqual(
            FrozenCollectionCopy.groupEmptyMessage(group: "空分组"),
            "新建的凭证会直接落进「空分组」；已有凭证可以在它的详情页里移入。"
        )
        XCTAssertEqual(
            FrozenCollectionCopy.recycleSubtitle,
            "删除的凭证保留 30 天，到期自动彻底删除；Agent 无法访问回收站。"
        )
        XCTAssertEqual(
            FrozenCollectionCopy.recycleEmptyMessage,
            "从详情页删除的凭证会在这里保留 30 天。"
        )
    }

    func testEraseConfirmationStartsEmptyWithFrozenLabelAndPlaceholder() {
        XCTAssertEqual(FrozenEraseConfirmationPresentation.label, "输入「抹除」以确认")
        XCTAssertEqual(FrozenEraseConfirmationPresentation.placeholder, "抹除")
        XCTAssertEqual(FrozenEraseConfirmationPresentation.initialText, "")

        AppLanguage.current = "en"
        XCTAssertEqual(FrozenEraseConfirmationPresentation.label, "Type ERASE to confirm")
        XCTAssertEqual(FrozenEraseConfirmationPresentation.placeholder, "ERASE")
        XCTAssertTrue(FrozenEraseConfirmationPresentation.accepts("ERASE"))
        XCTAssertFalse(FrozenEraseConfirmationPresentation.accepts("抹除"))
        AppLanguage.current = "zh-Hans"
        XCTAssertTrue(FrozenEraseConfirmationPresentation.accepts("抹除"))
        XCTAssertFalse(FrozenEraseConfirmationPresentation.accepts("ERASE"))
    }

    func testRequestCountdownAndRecycleDaysUseRealDates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            FrozenCountdown.format(deadline: now.addingTimeInterval(299), now: now),
            "4:59"
        )
        XCTAssertEqual(
            FrozenCountdown.format(deadline: now.addingTimeInterval(297), now: now),
            "4:57"
        )
        XCTAssertEqual(
            RecycleBinPresentation.remainingDaysCopy(
                deletedAt: now.addingTimeInterval(-5 * 24 * 60 * 60),
                now: now
            ),
            "剩余 25 天"
        )
    }

    func testFrozenTemplateFieldsAreHumanReadableChineseLabels() {
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "API_KEY"), "访问密钥")
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "SSH_HOST"), "服务器地址")
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "SSH_PRIVATE_KEY"), "私钥文件")
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "SECRET_ACCESS_KEY"), "访问密钥")
        XCTAssertEqual(CredentialTemplate.fieldTitle(for: "DB_PASSWORD"), "密码")
    }

    func testAPITemplateEditorPreservesSecretAndOptionalEndpointSemantics() throws {
        let fields = CredentialTemplate.api.components
        XCTAssertEqual(fields.map(\.name), ["API_KEY", "API_ENDPOINT"])
        XCTAssertEqual(fields.map(\.isSecret), [true, false])
        XCTAssertEqual(fields.map(\.isRemovable), [false, true])
        XCTAssertEqual(fields.map(FrozenEditorCopy.kindLabel), ["已保护", "文字"])

        let loaded = try CredentialEditorComponentLoader.load(
            [
                ManagedCredentialComponent(name: "API_KEY", value: .text("secret-token")),
                ManagedCredentialComponent(name: "API_ENDPOINT", value: .text("https://api.example.com")),
            ],
            template: .api
        )
        XCTAssertEqual(loaded.map(\.isSecret), [true, false])
        XCTAssertEqual(loaded.map(\.isRemovable), [false, true])
    }

    func testAPITemplateEditorUsesFrozenFieldCards() {
        XCTAssertEqual(
            CredentialTemplate.api.components.map(FrozenEditorCopy.fieldCard),
            [
                .init(
                    title: "访问密钥",
                    help: "服务提供方给你的 Key 或 Token"
                ),
                .init(
                    title: "API 端点（可选）",
                    help: "例如 https://api.example.com；不需要可以留空或移除"
                ),
            ]
        )
    }

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
        XCTAssertEqual(
            FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: true),
            ["仅本次", "允许 30 分钟", "拒绝"]
        )
        XCTAssertEqual(
            FrozenApprovalActions.titles(operation: .read, timedAllowanceEnabled: false),
            ["仅本次", "拒绝"]
        )
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
            ["每次使用前问我（推荐）", "始终允许使用", "不允许 Agent 使用"]
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
        XCTAssertEqual(WorkspaceVisualContract.accentHex, "0A6CFF")
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
                message: "已有 2 份凭证受保护。Agent 请旨不受影响，仍会直接弹出确认框。",
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
                message: "1 credential is protected. Agent requests still appear for you to decide.",
                action: "Unlock Management"
            )
        )
    }

    func testEnglishWorkspaceSurfacesContainNoChineseCopy() {
        AppLanguage.current = "en"
        defer { AppLanguage.current = "zh-Hans" }
        let conflict = FrozenImportConflictPresentation(existingName: "Existing", choice: .replace)
        let strings = CredentialTemplate.allCases.flatMap { [$0.prototypeTitle, $0.prototypeDescription] }
            + CredentialPermission.prototypeCases.map(\.prototypeTitle)
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

    @MainActor
    private func manager(
        _ viewModel: VaultViewModel,
        section: CredentialWorkspaceSection = .all,
        route: CredentialWorkspaceRoute = .library,
        selectedID: String? = nil,
        pendingRequests: [BrokerApprovalOperationRequest] = [],
        readAuthenticationConfirmation: Bool = false,
        editorExpanded: Bool = false,
        importValues: [(name: String, value: String)] = [],
        settingsErase: Bool = false,
        credentialDeleteConfirmation: String? = nil,
        groupDeleteConfirmation: String? = nil,
        accessRecordClearConfirmation: Bool = false
    ) -> some View {
        CredentialManagementView(
            initialSection: section, initialRoute: route,
            selectedCredentialID: selectedID, previewMode: true,
            previewPendingRequests: pendingRequests,
            previewReadAuthenticationConfirmation: readAuthenticationConfirmation,
            previewEditorExpanded: editorExpanded,
            previewImportValues: importValues,
            previewSettingsErase: settingsErase,
            previewCredentialDeleteConfirmation: credentialDeleteConfirmation,
            previewGroupDeleteConfirmation: groupDeleteConfirmation,
            previewAccessRecordClearConfirmation: accessRecordClearConfirmation
        )
        .environment(viewModel)
    }

    @MainActor
    private func makeSwiftUILikeManagementWindow(viewModel: VaultViewModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 980, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.title = "请旨"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .environment(viewModel)
                .frame(
                    width: WorkspaceVisualContract.windowWidth,
                    height: WorkspaceVisualContract.windowHeight
                )
        )
        window.setContentSize(ManagementWindowConfiguration.frameSize)
        return window
    }

    @MainActor
    private func pumpWindowLayout(_ window: NSWindow, times: Int = 24) {
        for _ in 0..<times {
            window.contentView?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))
        }
    }

    @MainActor
    private func makePreviewViewModel(defaults: UserDefaults? = nil) -> VaultViewModel {
        let suite = "WorkspaceVisualContractTests-\(UUID().uuidString)"
        let defaults = defaults ?? UserDefaults(suiteName: suite) ?? .standard
        defaults.set("zh-Hans", forKey: "languageMode")
        defaults.set("light", forKey: "appearanceMode")
        return VaultViewModel(
            runtimeFileCleanupFailures: { false },
            accessRecords: .empty,
            eraseLocalLibrary: { _, _, _ in },
            authenticateDeviceOwner: { _ in .allow },
            preferences: AppPreferences(defaults: defaults),
            loginItem: LoginItemController(isEnabled: { true }, setEnabled: { _ in }),
            credentialMutations: .readOnly { ([], [], [], false) }
        )
    }

    private func credential(
        id: String,
        name: String,
        group: String?,
        deletedAt: Date? = nil
    ) -> ManagedTextCredential {
        let componentNames: [String]
        if name.contains("部署") {
            componentNames = ["SSH_HOST"]
        } else if name.contains("数据库") {
            componentNames = ["DB_HOST", "DB_PASSWORD"]
        } else {
            componentNames = ["API_KEY", "API_ENDPOINT"]
        }
        return ManagedTextCredential(
            id: id, name: name, value: nil, usageInstructions: "仅用于批准的发布流程",
            privateNotes: nil, groupName: group, environmentVariable: nil,
            permission: .ask, expiresAt: nil, payloadKind: .bundle,
            originalFilename: nil, byteSize: nil, contentDigest: nil, fileBytes: nil,
            components: componentNames.map { ManagedCredentialComponent(name: $0, value: nil) },
            deletedAt: deletedAt
        )
    }

    private func pendingApproval(operationID: String) -> BrokerPendingApproval {
        .init(
            requestID: "request-\(operationID)",
            capability: "capability-\(operationID)",
            request: .init(
                operationID: operationID,
                credentialID: "credential",
                targetID: "credential",
                operation: .read,
                payloadDigest: "redacted"
            )
        )
    }

    private func evidenceDirectory() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AskKeyWorkspaceUI-\(UUID().uuidString)", isDirectory: true)
    }

    @MainActor
    private func render<V: View>(
        _ view: V,
        as name: String,
        in directory: URL,
        size: CGSize = .init(width: 980, height: 620)
    ) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Color.white)
        )
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
        XCTAssertGreaterThan(data.count, 5_000, "\(name) did not render useful evidence")
    }
}
