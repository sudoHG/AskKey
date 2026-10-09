import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

/// Write cards: the subtitle that says what a change does, and in Details
/// plain-language item rows with exact status tags and what happens after
/// approval.
@MainActor
final class FrozenWriteSummaryContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func content(_ summary: BrokerCredentialWriteSummary) -> FrozenWriteSummaryContent {
        FrozenWriteSummaryContent(summary: summary, requester: "Claude Code")
    }

    private func lines(_ content: FrozenWriteSummaryContent) -> [String] {
        content.components.map(\.line.plainText)
    }

    private func modification(before: [BrokerCredentialComponentSummary], after: [BrokerCredentialComponentSummary],
                              beforeDigest: String? = "old", afterDigest: String? = "new") -> BrokerCredentialWriteSummary {
        .init(credentialName: "Release Check", operation: .modify, before: before, after: after,
              beforeDigest: beforeDigest, afterDigest: afterDigest, beforeUsageInstructions: "Use for release checks.",
              afterUsageInstructions: "Use for release checks.", beforeGroup: "Release Tools", afterGroup: "Release Tools")
    }

    func testCreateListsEveryItemWithItsValueAndStatesThePermission() {
        Fixtures.withLanguages { language in
            let create = content(Fixtures.createSummary)
            if language == "en" {
                XCTAssertEqual(create.itemsHeading, "Items (3, values provided by Claude Code)")
                XCTAssertEqual(lines(create), [
                    "TOKEN · 28 bytes · given to programs as environment variable RELEASE_CHECK_TOKEN",
                    "CERT · 1,234 bytes · given to programs as a temporary file (path in RELEASE_CERT_FILE)",
                    "RECOVERY_CODE · 16 bytes · kept in Ask Key only, never given to agents",
                ])
                XCTAssertEqual(create.consequence,
                    "Its agent permission will be Ask every time, so agents need your approval for each use.")
            } else {
                XCTAssertEqual(create.itemsHeading, "凭证内容（3 项，值由 Claude Code 提供）") // i18n-literal: Assert the Simplified Chinese items heading.
                XCTAssertEqual(lines(create), [
                    "TOKEN · 28 字节 · 使用时作为环境变量 RELEASE_CHECK_TOKEN 交给程序", // i18n-literal: Assert the Simplified Chinese item row.
                    "CERT · 1,234 字节 · 使用时作为临时文件交给程序（路径在 RELEASE_CERT_FILE）", // i18n-literal: Assert the Simplified Chinese item row.
                    "RECOVERY_CODE · 16 字节 · 只存在请旨里，不交给任何 Agent", // i18n-literal: Assert the Simplified Chinese item row.
                ])
                XCTAssertEqual(create.consequence, "这个凭证的 Agent 权限是「每次询问」：Agent 每次使用都要你批准。") // i18n-literal: Assert the Simplified Chinese permission statement.
            }
            XCTAssertEqual(create.components.map(\.tag), [nil, nil, nil], "create rows carry no status tags")
            XCTAssertEqual(create.components.first?.line.segments.filter(\.code).map(\.text), ["RELEASE_CHECK_TOKEN"])
            XCTAssertEqual(create.valueComponents.map(\.name), ["TOKEN", "CERT", "RECOVERY_CODE"])
            XCTAssertEqual(create.instructions, .current("Use only for the release smoke check. Keep values out of logs."))
            XCTAssertEqual(create.group, .current("“Release Tools”"))
            XCTAssertTrue(create.createsGroup)
            XCTAssertFalse(create.isDestructive)
        }
    }

    func testMetadataOnlyChangeTagsEveryItemUnchanged() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.metadataSummary)
            XCTAssertEqual(modify.components.map(\.tag), [.unchanged, .unchanged], "Details list every item with its tag")
            XCTAssertTrue(modify.valueComponents.isEmpty)
            XCTAssertEqual(modify.instructionsTag, .changed)
            XCTAssertEqual(modify.group, .unchanged)
            XCTAssertFalse(modify.valueOnlyChange)
            XCTAssertFalse(modify.isDestructive)
            XCTAssertNil(modify.consequence)
            XCTAssertEqual(modify.subtitle, language == "en"
                ? "Changes the instructions (some instruction text is deleted)"
                : "更改使用说明（删掉了部分说明）") // i18n-literal: Assert the Simplified Chinese change subtitle.
        }
    }

    func testValueOnlyChangeTagsTheReplacementAndWarnsAboutTheOldValue() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.valueSummary)
            XCTAssertTrue(modify.valueOnlyChange)
            XCTAssertTrue(modify.isDestructive)
            XCTAssertEqual(modify.components.map(\.tag), [.replaced])
            XCTAssertEqual(modify.components.map(\.overwrites), [true])
            XCTAssertEqual(modify.valueComponents.map(\.byteCount), [52])
            XCTAssertEqual(modify.instructions, .unchanged)
            let replacement = modify.components.first?.notes.map(\.plainText)
            if language == "en" {
                XCTAssertEqual(lines(modify), ["TOKEN · given to programs as environment variable RELEASE_CHECK_TOKEN"])
                XCTAssertEqual(replacement, ["Old value 40 bytes → new value 52 bytes (new value from Claude Code)"])
                XCTAssertEqual(modify.subtitle, "The old value can't be recovered")
                XCTAssertEqual(modify.itemsHeading, "Items (1, new values provided by Claude Code)")
                XCTAssertEqual(appLocalized("If you approve, the old value is overwritten and can't be recovered."),
                               "If you approve, the old value is overwritten and can't be recovered.")
            } else {
                XCTAssertEqual(replacement, ["旧值 40 字节 → 新值 52 字节（新值由 Claude Code 提供）"]) // i18n-literal: Assert the Simplified Chinese replacement row.
                XCTAssertEqual(modify.subtitle, "旧值将无法找回") // i18n-literal: Assert the Simplified Chinese value subtitle.
                XCTAssertEqual(modify.itemsHeading, "凭证内容（1 项，新值由 Claude Code 提供）") // i18n-literal: Assert the Simplified Chinese items heading.
                XCTAssertEqual(appLocalized("If you approve, the old value is overwritten and can't be recovered."),
                               "批准后旧值会被覆盖，无法找回。") // i18n-literal: Assert the Simplified Chinese overwrite line.
            }
        }
    }

    func testAddedItemLeavesTheOthersUnchanged() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.addedSummary)
            XCTAssertEqual(modify.components.map(\.tag), [.unchanged, .unchanged, .new])
            XCTAssertEqual(modify.valueComponents.map(\.name), ["CERT"], "only the new value is listed")
            XCTAssertFalse(modify.valueOnlyChange)
            XCTAssertFalse(modify.isDestructive, "adding an item loses nothing")
            XCTAssertEqual(modify.subtitle, language == "en" ? "Adds 1 item" : "新增 1 项") // i18n-literal: Assert the Simplified Chinese change subtitle.
            XCTAssertEqual([ApprovalTag.unchanged, .new, .replaced].map(\.title), language == "en"
                ? ["Unchanged", "New", "Replaced"] : ["不变", "新增", "替换"]) // i18n-literal: Assert Simplified Chinese tags.
        }
    }

    func testEachItemIsTaggedFromItsOwnValueDigest() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "en"
        let token = Fixtures.token
        let user = Fixtures.user
        let rotated = Fixtures.component("TOKEN", bytes: 28, .environmentVariable("RELEASE_CHECK_TOKEN"), value: "rotated")
        XCTAssertEqual(content(modification(before: [token, user], after: [rotated, user])).components.map(\.tag),
                       [.replaced, .unchanged], "same size and delivery, different value")
        XCTAssertEqual(content(modification(before: [token, user], after: [token, user],
                                            beforeDigest: "same", afterDigest: "same")).components.map(\.tag), [.unchanged, .unchanged])
        let moved = Fixtures.component("TOKEN", bytes: 28, .temporaryFile("RELEASE_CHECK_FILE"))
        let changed = content(modification(before: [token, user], after: [moved]))
        XCTAssertEqual(changed.components.map(\.tag), [.changed, .removed])
        XCTAssertEqual(changed.components.first?.notes.map(\.plainText),
                       ["Before: TOKEN · 28 bytes · given to programs as environment variable RELEASE_CHECK_TOKEN"])
        XCTAssertTrue(changed.valueComponents.isEmpty, "a new delivery for the same value adds no value to view")
        XCTAssertEqual(changed.subtitle, "Changes the settings of 1 item, removes 1 item; the removed value can't be recovered")
        XCTAssertTrue(changed.isDestructive)
        // Summaries without per-item digests claim a replacement rather than "unchanged".
        let legacy = BrokerCredentialComponentSummary(name: "TOKEN", payloadKind: .text, byteCount: 28,
            delivery: .environmentVariable("RELEASE_CHECK_TOKEN"), masked: true)
        XCTAssertEqual(content(modification(before: [legacy], after: [legacy])).components.map(\.tag), [.replaced])
    }

    func testVaultRotationOfOneSameLengthItemShowsReplacedAndUnchanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyCardDigest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vault = Vault(store: try VaultStore(path: directory.appendingPathComponent("vault.db").path),
                          key: SymmetricKey(data: Data(repeating: 0x42, count: 32)))
        try vault.beginManagementSession(using: .allow)
        _ = try vault.createBundleCredential(.init(name: "Release Check", components: [
            .init(name: "USER", value: .text("synthetic-user"), delivery: .environmentVariable("RELEASE_USER")),
            .init(name: "TOKEN", value: .text("synthetic-token-aaaa"), delivery: .environmentVariable("RELEASE_TOKEN")),
        ], usageInstructions: "Use for release checks.", groupName: nil, permission: .ask), using: .allow)
        let request = AgentTextWriteRequest(operationID: "rotate", action: .modifyBundle(name: "Release Check", changes: [
            .upsert(.init(name: "TOKEN", value: .text("synthetic-token-bbbb"), delivery: .environmentVariable("RELEASE_TOKEN"))),
        ]))
        guard case .submitted(let ticket) = try vault.requestAgentTextWrite(request) else { return XCTFail("Expected a pending write") }
        let summary = try vault.frozenAgentWriteSummary(operationID: request.operationID,
            requestID: ticket.requestID, capability: ticket.capability)
        let card = content(summary)
        XCTAssertEqual(card.components.map(\.name), ["USER", "TOKEN"])
        XCTAssertEqual(card.components.map(\.tag), [.unchanged, .replaced])
        XCTAssertEqual(card.valueComponents.map(\.name), ["TOKEN"])
        XCTAssertTrue(card.valueOnlyChange)
    }

    func testInstructionEditsAreHighlightedWordByWord() {
        let diff = ApprovalTextDiff(before: "Use for release checks. Keep values out of logs.",
                                    after: "Use only for the nightly release checks.")
        XCTAssertEqual(diff.before.map(\.text).joined(), "Use for release checks. Keep values out of logs.")
        XCTAssertEqual(diff.after.map(\.text).joined(), "Use only for the nightly release checks.")
        XCTAssertEqual(diff.after.filter { $0.kind == .added }.map(\.text), ["only ", "the nightly "])
        XCTAssertEqual(diff.removedPhrases, ["Keep values out of logs"])
        let chinese = ApprovalTextDiff(before: "只用于发布检查，不要写进日志。", after: "只用于夜间发布检查。") // i18n-literal: Synthetic Chinese instructions.
        XCTAssertEqual(chinese.after.filter { $0.kind == .added }.map(\.text), ["夜间"]) // i18n-literal: Synthetic Chinese diff.
        XCTAssertEqual(chinese.removedPhrases, ["不要写进日志"]) // i18n-literal: Synthetic Chinese diff.
        Fixtures.withLanguages { language in
            XCTAssertEqual(appLocalizedFormat("Removed phrases: %@", ApprovalCopy.quoted("Keep values out of logs.")), language == "en"
                ? "Removed: “Keep values out of logs.”" : "删掉了：“Keep values out of logs.”") // i18n-literal: Assert the Simplified Chinese removed line.
            let modify = content(Fixtures.metadataSummary)
            XCTAssertEqual(modify.instructionsDiff?.removedPhrases, ["checks"])
            XCTAssertEqual(modify.instructionsDiff?.after.filter { $0.kind == .added }.map(\.text), ["only ", "the nightly ", "check"])
        }
    }

    func testDeleteShowsWhatIsDeletedAndWhereItGoes() {
        Fixtures.withLanguages { language in
            let delete = content(Fixtures.deleteSummary)
            XCTAssertEqual(delete.components.map(\.tag), [nil, nil])
            XCTAssertTrue(delete.valueComponents.isEmpty)
            XCTAssertEqual(delete.itemsHeading, language == "en" ? "Items (2)" : "凭证内容（2 项）") // i18n-literal: Assert the Simplified Chinese items heading.
            XCTAssertEqual(delete.instructions, .current("Use for release checks."))
            XCTAssertNil(delete.subtitle, "the card states the Recycle Bin for every delete")
            XCTAssertFalse(delete.isDestructive, "a deleted credential can be restored")
            XCTAssertEqual(delete.consequence, language == "en"
                ? "It moves to the Recycle Bin for 30 days and can be restored there, then it is removed permanently. Agents can't use or see it meanwhile."
                : "凭证会移到回收站保留 30 天，期间可以在回收站恢复，之后永久删除。这段时间里 Agent 不能使用，也看不到它。") // i18n-literal: Assert the Simplified Chinese delete statement.
        }
    }

    func testNewGroupTagIsNeutralAndExplained() {
        Fixtures.withLanguages { language in
            XCTAssertEqual([ApprovalTag.newGroup.title, appLocalized("Created when you approve")], language == "en"
                ? ["New group", "Created when you approve"] : ["新分组", "批准后创建"]) // i18n-literal: Assert the Simplified Chinese new-group tag.
            XCTAssertEqual(ApprovalTag.newGroup.color, Theme.text, "a new group is not a warning")
            XCTAssertEqual(ApprovalTag.removed.color, Theme.warning)
            XCTAssertEqual(ApprovalTag.unchanged.color, Theme.textSecondary)
        }
    }

    func testNothingChangedIsSaidPlainly() {
        Fixtures.withLanguages { language in
            let same = content(modification(before: [Fixtures.token], after: [Fixtures.token], beforeDigest: "same", afterDigest: "same"))
            XCTAssertEqual(same.subtitle, language == "en" ? "Nothing changes" : "不会改动任何内容") // i18n-literal: Assert the Simplified Chinese no-change subtitle.
        }
    }

    func testChangeSubtitlesListEveryKindOfChangeAndWhatIsLost() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let rotated = Fixtures.component("TOKEN", bytes: 28, .environmentVariable("RELEASE_CHECK_TOKEN"), value: "rotated")
        let rotatedUser = Fixtures.component("USER", bytes: 12, .environmentVariable("RELEASE_USER"), value: "rotated")
        let moved = Fixtures.component("USER", bytes: 12, .temporaryFile("RELEASE_USER_FILE"))
        let everything = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
            before: [Fixtures.token, Fixtures.user, Fixtures.recovery], after: [rotated, moved, Fixtures.certificate],
            beforeDigest: "old", afterDigest: "new", beforeUsageInstructions: "Use for release checks. Keep values out of logs.",
            afterUsageInstructions: "Use for release checks.", beforeGroup: nil, afterGroup: "Operations", createsGroup: true)
        let twoValues = modification(before: [Fixtures.token, Fixtures.user], after: [rotated, rotatedUser])
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            XCTAssertEqual(content(everything).subtitle, language == "en"
                ? "Replaces 1 value, changes the settings of 1 item, changes the instructions and the group (some instruction text is deleted), adds 1 item, removes 1 item; the old and removed values can't be recovered"
                : "替换 1 项的值，更改 1 项的设置，更改使用说明和分组（删掉了部分说明），新增 1 项，移除 1 项，旧值和移除的值将无法找回") // i18n-literal: Assert the Simplified Chinese change subtitle.
            XCTAssertEqual(content(twoValues).subtitle, language == "en"
                ? "The old values can't be recovered" : "旧值将无法找回") // i18n-literal: Assert the Simplified Chinese value subtitle.
        }
        XCTAssertTrue(content(everything).isDestructive)
        XCTAssertFalse(content(everything).valueOnlyChange)
        XCTAssertTrue(content(twoValues).valueOnlyChange)
    }

    func testCreateSubtitleNamesTheGroupAndOmitsUngrouped() {
        Fixtures.withLanguages { language in
            XCTAssertEqual(content(Fixtures.createSummary).subtitle, language == "en"
                ? "In the new group “Release Tools”" : "放进新分组“Release Tools”") // i18n-literal: Assert the Simplified Chinese create subtitle.
            XCTAssertEqual(content(Fixtures.createTwoItemsSummary).subtitle, language == "en"
                ? "In the group “Staging”" : "放进“Staging”") // i18n-literal: Assert the Simplified Chinese create subtitle.
            XCTAssertNil(content(Fixtures.createUngroupedSummary).subtitle)
        }
    }
}
