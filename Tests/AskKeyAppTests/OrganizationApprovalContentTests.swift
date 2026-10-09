import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Organize cards: the subtitle that counts steps, merges and hidden
/// credentials, and in Details the steps as sentences with no-change and
/// merge tags, in both languages.
@MainActor
final class OrganizationApprovalContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    func testRegularStepsReadAsSentences() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.regularOrganization, requester: "Claude Code")
            XCTAssertEqual(content.rows.map(\.number), [1, 2, 3, 4])
            XCTAssertEqual(content.rows.map(\.tag), [nil, nil, nil, nil])
            XCTAssertNil(content.rows[0].detail, "a new group needs no second line")
            XCTAssertFalse(content.isDestructive, "deleting a group leaves its credentials in Ungrouped")
            let titles = content.rows.map(\.title)
            let details = content.rows.map(\.detail)
            if language == "en" {
                XCTAssertEqual(titles, [
                    "Create the group “Staging Services”",
                    "Move the credential “Staging API” from “Old Services” to “Staging Services”",
                    "Rename the group “Old Services” to “Renamed Services”",
                    "Delete the group “Temp”",
                ])
                XCTAssertEqual(details, [nil, nil, "When it's renamed, the group has 3 credentials (2 hidden from agents).",
                    "Its 1 credential won't be deleted and will become “Ungrouped”."])
            } else {
                XCTAssertEqual(titles, [
                    "新建分组“Staging Services”", // i18n-literal: Assert the Simplified Chinese organize step.
                    "把凭证“Staging API”从“Old Services”移到“Staging Services”", // i18n-literal: Assert the Simplified Chinese organize step.
                    "把分组“Old Services”改名为“Renamed Services”", // i18n-literal: Assert the Simplified Chinese organize step.
                    "删除分组“Temp”", // i18n-literal: Assert the Simplified Chinese organize step.
                ])
                XCTAssertEqual(details, [nil, nil, "改名时组里有 3 个凭证（其中 2 个对 Agent 隐藏）。", // i18n-literal: Assert the Simplified Chinese step detail.
                    "组里 1 个凭证不会被删除，会变成“未分组”。"]) // i18n-literal: Assert the Simplified Chinese step detail.
            }
        }
    }

    func testExistingGroupAndMergeStartWithTheirTagsAndStateTheResult() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.existingAndMerge, requester: "Claude Code")
            XCTAssertEqual(content.rows.map(\.tag), [.noChange, .merge])
            XCTAssertTrue(content.isDestructive, "a merge cannot be undone automatically")
            if language == "en" {
                XCTAssertEqual(content.rows.map(\.tag?.title), ["No change", "Merge"])
                XCTAssertEqual(content.rows[0].title, "Create the group “Existing Private Services”")
                XCTAssertEqual(content.rows[0].detail,
                    "This group already exists, so nothing is created or changed. It has 1 credential (1 hidden from agents).")
                XCTAssertEqual(content.rows[1].title,
                    "Claude Code asked to rename “Merge Source” to “Existing Merge Services”; “Existing Merge Services” already exists and is hidden from it, so the groups merge.")
                XCTAssertEqual(content.rows[1].detail,
                    "“Merge Source” disappears and “Existing Merge Services” will have 4 credentials (3 hidden from agents). A merge can't be undone automatically.")
            } else {
                XCTAssertEqual(content.rows.map(\.tag?.title), ["无变化", "合并"]) // i18n-literal: Assert Simplified Chinese organize tags.
                XCTAssertEqual(content.rows[0].detail,
                    "这个分组已经存在，不会新建或改动任何内容。组里有 1 个凭证（其中 1 个对 Agent 隐藏）。") // i18n-literal: Assert the Simplified Chinese no-op detail.
                XCTAssertEqual(content.rows[1].title,
                    "Claude Code 请求的是把“Merge Source”改名为“Existing Merge Services”；“Existing Merge Services”已存在且对它隐藏，所以实际会合并。") // i18n-literal: Assert the Simplified Chinese merge step.
                XCTAssertEqual(content.rows[1].detail,
                    "合并后“Merge Source”消失，“Existing Merge Services”共有 4 个凭证（其中 3 个对 Agent 隐藏）。合并无法自动撤销。") // i18n-literal: Assert the Simplified Chinese merge result.
            }
        }
    }

    func testHiddenClauseIsOmittedAtZeroAndEmptyGroupsSaySo() {
        Fixtures.withLanguages { language in
            let summary = BrokerOrganizationSummary(operations: [
                .renameGroup(from: "Old", to: "New", members: 2, nonvisible: 0),
                .deleteGroup(name: "Unused", members: 0, nonvisible: 0),
                .existingGroup(name: "Shared", members: 0, nonvisible: 0),
            ])
            let details = FrozenOrganizationSummaryContent(summary: summary, requester: "Claude Code").rows.map(\.detail)
            XCTAssertEqual(details, language == "en"
                ? ["When it's renamed, the group has 2 credentials.", "The group is empty.",
                   "This group already exists, so nothing is created or changed. The group is empty."]
                : ["改名时组里有 2 个凭证。", "组里没有凭证。", "这个分组已经存在，不会新建或改动任何内容。组里没有凭证。"]) // i18n-literal: Assert Simplified Chinese member counts.
            XCTAssertFalse(FrozenOrganizationSummaryContent(summary: BrokerOrganizationSummary(operations: [
                .createGroup("New"), .move(credential: "API", from: nil, to: "New"),
            ]), requester: "Claude Code").isDestructive)
        }
    }

    func testTwelveStepsAreNumberedAndCountedInTheSubtitle() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.twelveSteps, requester: "Claude Code")
            XCTAssertEqual(content.rows.map(\.number), Array(1...12))
            XCTAssertFalse(content.isDestructive)
            if language == "en" {
                XCTAssertEqual(content.subtitle, "12 steps, affecting 3 hidden credentials")
                XCTAssertEqual(content.rows[1].title, "Move the credential “Service 2” from “Ungrouped” to “Group 1”")
            } else {
                XCTAssertEqual(content.subtitle, "共 12 步，会动到 3 个隐藏的凭证") // i18n-literal: Assert the Simplified Chinese organize subtitle.
                XCTAssertEqual(content.rows[1].title, "把凭证“Service 2”从“未分组”移到“Group 1”") // i18n-literal: Assert the Simplified Chinese move step.
            }
        }
    }

    func testHiddenCredentialsAreCountedOnceAcrossSteps() {
        func hidden(_ operations: [BrokerOrganizationSummary.Operation]) -> Int {
            FrozenOrganizationSummaryContent.hiddenCredentials(BrokerOrganizationSummary(operations: operations))
        }
        XCTAssertEqual(hidden([.renameGroup(from: "Old", to: "New", members: 3, nonvisible: 2),
                               .deleteGroup(name: "new", members: 3, nonvisible: 2)]), 2, "a renamed group deleted later")
        XCTAssertEqual(hidden([.mergeGroup(from: "C", to: "B", members: 2, nonvisible: 1, targetMembers: 1, targetNonvisible: 1),
                               .deleteGroup(name: "B", members: 3, nonvisible: 2)]), 2,
                       "a merged-in credential and the target's own each count once")
        XCTAssertEqual(hidden([.existingGroup(name: "Shared", members: 2, nonvisible: 2),
                               .move(credential: "API", from: nil, to: "Shared"), .createGroup("Empty")]), 0,
                       "steps that change no hidden credential's group")
        Fixtures.withLanguages { language in
            let one = FrozenOrganizationSummaryContent(summary: BrokerOrganizationSummary(operations: [
                .mergeGroup(from: "A", to: "B", members: 1, nonvisible: 1, targetMembers: 0, targetNonvisible: 0),
            ]), requester: "Claude Code")
            let two = FrozenOrganizationSummaryContent(summary: BrokerOrganizationSummary(operations: [
                .mergeGroup(from: "A", to: "B", members: 1, nonvisible: 0, targetMembers: 0, targetNonvisible: 0),
                .mergeGroup(from: "C", to: "D", members: 1, nonvisible: 0, targetMembers: 0, targetNonvisible: 0),
            ]), requester: "Claude Code")
            XCTAssertEqual([one.subtitle, two.subtitle], language == "en"
                ? ["1 step, one of which merges groups, affecting 1 hidden credential", "2 steps, 2 of which merge groups"]
                : ["共 1 步，其中一步会合并分组，会动到 1 个隐藏的凭证", "共 2 步，其中 2 步会合并分组"]) // i18n-literal: Assert Simplified Chinese organize subtitles.
            XCTAssertTrue(two.isDestructive)
        }
    }
}
