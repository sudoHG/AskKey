import XCTest
import CryptoKit
import AppKit
import SwiftUI
import AskKeyBroker
@testable import AskKeyVault
@testable import AskKeyAppKit

@MainActor
final class CredentialEditorVisualTests: WorkspaceVisualContractTestSupport {
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
        let previous = AppLanguage.current
        AppLanguage.current = "en"
        XCTAssertEqual(RecycleBinPresentation.credentialMarker(name: ""), "C")
        XCTAssertEqual(RecycleBinPresentation.credentialMarker(name: "旧数据库账号"), "旧")
        AppLanguage.current = previous
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

    func testImportPreviewUsesFrozenExplanations() {
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
            ["API 访问凭证", "2 项内容", "每次询问（推荐）", "发布"]
        )
        XCTAssertEqual(
            CredentialListPresentation(
                credential: credential(id: "ssh", name: "部署服务器", group: nil)
            ).tags,
            ["SSH 登录身份", "1 项内容", "每次询问（推荐）", "未分组"]
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
}
