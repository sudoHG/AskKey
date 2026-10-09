import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Write cards: plain-language item rows, status tags, the change summary,
/// the value box and what happens after approval.
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

    func testCreateListsEveryItemInPlainWordsAndStatesThePermission() {
        Fixtures.withLanguages { language in
            let create = content(Fixtures.createSummary)
            if language == "en" {
                XCTAssertEqual(lines(create), [
                    "TOKEN · 28 bytes · given to programs as environment variable RELEASE_CHECK_TOKEN",
                    "CERT · 1,234 bytes · given to programs as a temporary file (path in RELEASE_CERT_FILE)",
                    "RECOVERY_CODE · 16 bytes · kept in Ask Key only, never given to agents",
                ])
                XCTAssertEqual(create.afterApproval,
                    "The credential's agent permission will be Ask every time: agents need your approval each time they use it.")
                XCTAssertEqual(create.valueHeading, "Value to save (provided by Claude Code)")
                XCTAssertEqual(appLocalizedFormat("Items (%lld)", create.itemCount), "Items (3)")
            } else {
                XCTAssertEqual(lines(create), [
                    "TOKEN · 28 字节 · 使用时作为环境变量 RELEASE_CHECK_TOKEN 交给程序", // i18n-literal: Assert the Simplified Chinese item row.
                    "CERT · 1,234 字节 · 使用时作为临时文件交给程序（路径在 RELEASE_CERT_FILE）", // i18n-literal: Assert the Simplified Chinese item row.
                    "RECOVERY_CODE · 16 字节 · 只存在请旨里，不交给任何 Agent", // i18n-literal: Assert the Simplified Chinese item row.
                ])
                XCTAssertEqual(create.afterApproval, "这个凭证的 Agent 权限是「每次询问」：Agent 每次使用都要你批准。") // i18n-literal: Assert the Simplified Chinese permission statement.
                XCTAssertEqual(create.valueHeading, "要保存的值（由 Claude Code 提供）") // i18n-literal: Assert the Simplified Chinese value heading.
                XCTAssertEqual(appLocalizedFormat("Items (%lld)", create.itemCount), "凭证内容（3 项）") // i18n-literal: Assert the Simplified Chinese items heading.
            }
            XCTAssertEqual(create.components.map(\.tag), [nil, nil, nil], "create rows carry no status tags")
            XCTAssertEqual(create.components.first?.line.segments.filter(\.code).map(\.text), ["RELEASE_CHECK_TOKEN"])
            XCTAssertEqual(create.valueComponents.map(\.name), ["TOKEN", "CERT", "RECOVERY_CODE"])
            XCTAssertEqual(create.instructions, .current("Use only for the release smoke check. Keep values out of logs."))
            XCTAssertEqual(create.group.plain, .current(language == "en" ? "“Release Tools”" : "「Release Tools」")) // i18n-literal: Chinese corner brackets.
            XCTAssertTrue(create.createsGroup)
            XCTAssertNil(create.changeSummary)
        }
    }

    func testMetadataOnlyChangeFoldsUnchangedSectionsIntoTheSummary() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.metadataSummary)
            XCTAssertTrue(modify.components.isEmpty, "unchanged items collapse into the summary line")
            XCTAssertTrue(modify.valueComponents.isEmpty, "no value box without a new or replaced value")
            XCTAssertEqual(modify.instructionsTag, .changed)
            XCTAssertEqual(modify.group, .unchanged)
            XCTAssertFalse(modify.valueOnlyChange)
            if language == "en" {
                XCTAssertEqual(modify.changeSummary, "Changes: instructions · Unchanged: items, group")
                XCTAssertEqual(modify.instructions, .changed(before: "Use for release checks.", after: "Use only for the nightly release check."))
                XCTAssertEqual([appLocalized("Before"), appLocalized("After")], ["Before", "After"])
            } else {
                XCTAssertEqual(modify.changeSummary, "会改动：使用说明 · 不变：凭证内容、分组") // i18n-literal: Assert the Simplified Chinese change summary.
                XCTAssertEqual([appLocalized("Before"), appLocalized("After")], ["原来", "改为"]) // i18n-literal: Assert Simplified Chinese comparison labels.
            }
        }
    }

    func testValueOnlyChangeTagsTheReplacementAndNamesWhoProvidedIt() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.valueSummary)
            XCTAssertTrue(modify.valueOnlyChange)
            XCTAssertEqual(modify.components.map(\.tag), [.replaced])
            XCTAssertEqual(modify.componentsTag, .changed)
            XCTAssertTrue(modify.overwritesValues)
            XCTAssertEqual(modify.valueComponents.map(\.byteCount), [52])
            XCTAssertEqual(modify.instructions, .unchanged)
            let replacement = modify.components.first?.notes.map(\.plainText)
            if language == "en" {
                XCTAssertEqual(lines(modify), ["TOKEN · given to programs as environment variable RELEASE_CHECK_TOKEN"])
                XCTAssertEqual(replacement, ["old value 40 bytes → new value 52 bytes (new value from Claude Code)"])
                XCTAssertEqual(modify.changeSummary, "Changes: items · Unchanged: instructions, group")
                XCTAssertEqual(modify.valueHeading, "New value (provided by Claude Code)")
                XCTAssertEqual(ApprovalTag.replaced.title, "Replaced")
            } else {
                XCTAssertEqual(replacement, ["旧值 40 字节 → 新值 52 字节（新值由 Claude Code 提供）"]) // i18n-literal: Assert the Simplified Chinese replacement row.
                XCTAssertEqual(modify.changeSummary, "会改动：凭证内容 · 不变：使用说明、分组") // i18n-literal: Assert the Simplified Chinese change summary.
                XCTAssertEqual(ApprovalTag.replaced.title, "替换") // i18n-literal: Assert the Simplified Chinese tag.
            }
        }
    }

    func testAddedItemMarksSameSizeItemsAsPossiblyReplaced() {
        Fixtures.withLanguages { language in
            let modify = content(Fixtures.addedSummary)
            XCTAssertEqual(modify.components.map(\.tag), [.mayBeReplaced, .mayBeReplaced, .new])
            XCTAssertEqual(modify.valueComponents.map(\.name), ["TOKEN", "USER", "CERT"])
            XCTAssertFalse(modify.valueOnlyChange)
            XCTAssertEqual(modify.components.first?.notes.map(\.plainText), [language == "en"
                ? "Same size and delivery; Ask Key can't tell whether the value was replaced. Authenticate to view."
                : "大小和交付方式没变，无法确认值是否被替换；可验证后查看"]) // i18n-literal: Assert the Simplified Chinese uncertainty line.
            XCTAssertEqual([ApprovalTag.mayBeReplaced, .new].map(\.title), language == "en"
                ? ["May be replaced", "New"] : ["可能已替换", "新增"]) // i18n-literal: Assert Simplified Chinese tags.
        }
    }

    func testOnlyProvableStatesAreClaimed() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "en"
        let token = Fixtures.token
        let user = Fixtures.user
        // Equal digests prove nothing changed; the items section collapses.
        XCTAssertTrue(content(modification(before: [token], after: [token], beforeDigest: "same", afterDigest: "same")).components.isEmpty)
        // A lone same-size item whose digest changed was replaced.
        XCTAssertEqual(content(modification(before: [token], after: [token])).components.map(\.tag), [.replaced])
        // Missing digests prove nothing.
        XCTAssertEqual(content(modification(before: [token], after: [token], beforeDigest: nil, afterDigest: nil))
            .components.map(\.tag), [.mayBeReplaced])
        // Two same-size items: either may be the replaced one.
        XCTAssertEqual(content(modification(before: [token, user], after: [token, user])).components.map(\.tag),
                       [.mayBeReplaced, .mayBeReplaced])
        let moved = Fixtures.component("TOKEN", bytes: 28, .temporaryFile("RELEASE_CHECK_FILE"))
        let changed = content(modification(before: [token, user], after: [moved]))
        XCTAssertEqual(changed.components.map(\.tag), [.changed, .removed])
        XCTAssertEqual(changed.components.first?.notes.map(\.plainText), [
            "Before: TOKEN · 28 bytes · given to programs as environment variable RELEASE_CHECK_TOKEN",
            "Same size; Ask Key can't tell whether the value was replaced. Authenticate to view.",
        ])
        XCTAssertEqual(changed.valueComponents.map(\.name), ["TOKEN"], "a re-sent value may differ, so it can be viewed")
        XCTAssertEqual([ApprovalTag.changed, .removed].map(\.title), ["Changed", "Removed"])
    }

    func testDeleteShowsWhatIsDeletedAndWhereItGoes() {
        Fixtures.withLanguages { language in
            let delete = content(Fixtures.deleteSummary)
            XCTAssertEqual(delete.components.map(\.tag), [nil, nil])
            XCTAssertTrue(delete.valueComponents.isEmpty)
            XCTAssertEqual(delete.itemCount, 2)
            XCTAssertEqual(delete.instructions, .current("Use for release checks."))
            XCTAssertEqual(delete.afterApproval, language == "en"
                ? "It moves to the Recycle Bin for 30 days and can be restored there, then it is removed permanently. Agents can't use or see it meanwhile."
                : "凭证会移到回收站保留 30 天，期间可以在回收站恢复，之后永久删除。这段时间里 Agent 不能使用，也看不到它。") // i18n-literal: Assert the Simplified Chinese delete statement.
            XCTAssertEqual([appLocalized("Instructions for agents"), appLocalized("Group"), appLocalized("After you approve")],
                language == "en" ? ["Instructions for agents", "Group", "After you approve"]
                    : ["给 Agent 的使用说明", "分组", "批准后"]) // i18n-literal: Assert Simplified Chinese section headings.
        }
    }

    func testNewGroupTagIsNeutralAndExplained() {
        Fixtures.withLanguages { language in
            XCTAssertEqual([ApprovalTag.newGroup.title, appLocalized("created when you approve")], language == "en"
                ? ["New group", "created when you approve"] : ["新分组", "批准后创建"]) // i18n-literal: Assert the Simplified Chinese new-group tag.
            XCTAssertEqual(ApprovalTag.newGroup.color, Theme.text, "a new group is not a warning")
            XCTAssertEqual(ApprovalTag.removed.color, Theme.warning)
            XCTAssertEqual(ApprovalTag.unchanged.color, Theme.textSecondary)
        }
    }

    func testNothingChangedIsSaidPlainly() {
        Fixtures.withLanguages { language in
            let same = content(modification(before: [Fixtures.token], after: [Fixtures.token], beforeDigest: "same", afterDigest: "same"))
            XCTAssertEqual(same.changeSummary, language == "en" ? "Nothing changes" : "不会改动任何内容") // i18n-literal: Assert the Simplified Chinese no-change summary.
        }
    }
}

private extension FrozenWriteSummaryContent.Change {
    /// The displayed text without the word joiners that keep names whole.
    var plain: Self {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        switch self {
        case .current(let value): return .current(clean(value))
        case .changed(let before, let after): return .changed(before: clean(before), after: clean(after))
        case .unchanged: return .unchanged
        }
    }
}
