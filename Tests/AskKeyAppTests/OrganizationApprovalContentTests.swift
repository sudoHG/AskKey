import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Organize cards: steps as sentences, no-change and merge tags, hidden
/// counts and the step-counting button in both languages.
@MainActor
final class OrganizationApprovalContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func plain(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{2060}", with: "").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    func testRegularStepsReadAsSentences() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.regularOrganization)
            XCTAssertEqual(content.rows.map(\.number), [1, 2, 3, 4])
            XCTAssertEqual(content.rows.map(\.tag), [nil, nil, nil, nil])
            XCTAssertNil(content.rows[0].detail, "a new group needs no second line")
            XCTAssertTrue(content.isDestructive, "deleting a group is styled as destructive")
            let titles = content.rows.map { plain($0.title) }
            let details = content.rows.map { plain($0.detail) }
            if language == "en" {
                XCTAssertEqual(titles, [
                    "Create the group “Staging Services”",
                    "Move the credential “Staging API” from “Old Services” to “Staging Services”",
                    "Rename the group “Old Services” to “Renamed Services”",
                    "Delete the group “Temp”",
                ])
                XCTAssertEqual(details, [nil, nil, "It has 3 credentials (2 hidden from agents).",
                    "Its 1 credential won't be deleted and will become “Ungrouped”."])
            } else {
                XCTAssertEqual(titles, [
                    "新建分组「Staging Services」", // i18n-literal: Assert the Simplified Chinese organize step.
                    "把凭证「Staging API」从「Old Services」移到「Staging Services」", // i18n-literal: Assert the Simplified Chinese organize step.
                    "把分组「Old Services」改名为「Renamed Services」", // i18n-literal: Assert the Simplified Chinese organize step.
                    "删除分组「Temp」", // i18n-literal: Assert the Simplified Chinese organize step.
                ])
                XCTAssertEqual(details, [nil, nil, "组里有 3 个凭证（其中 2 个对 Agent 隐藏）。", // i18n-literal: Assert the Simplified Chinese step detail.
                    "组里 1 个凭证不会被删除，会变成「未分组」。"]) // i18n-literal: Assert the Simplified Chinese step detail.
            }
        }
    }

    func testExistingGroupAndMergeStartWithTheirTagsAndStateTheResult() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.existingAndMerge)
            XCTAssertEqual(content.rows.map(\.tag), [.noChange, .merge])
            XCTAssertTrue(content.isDestructive, "a merge cannot be undone automatically")
            if language == "en" {
                XCTAssertEqual(content.rows.map(\.tag?.title), ["No change", "Merge"])
                XCTAssertEqual(plain(content.rows[0].title), "Create the group “Existing Private Services”")
                XCTAssertEqual(content.rows[0].detail,
                    "This group already exists, so nothing is created or changed. It has 1 credential (1 hidden from agents).")
                XCTAssertEqual(plain(content.rows[1].title), "Merge the group “Merge Source” into the existing group “Existing Merge Services”")
                XCTAssertEqual(plain(content.rows[1].detail),
                    "“Merge Source” disappears and “Existing Merge Services” will have 4 credentials (3 hidden from agents). A merge can't be undone automatically.")
            } else {
                XCTAssertEqual(content.rows.map(\.tag?.title), ["无变化", "合并"]) // i18n-literal: Assert Simplified Chinese organize tags.
                XCTAssertEqual(content.rows[0].detail,
                    "这个分组已经存在，不会新建或改动任何内容。组里有 1 个凭证（其中 1 个对 Agent 隐藏）。") // i18n-literal: Assert the Simplified Chinese no-op detail.
                XCTAssertEqual(plain(content.rows[1].title), "把分组「Merge Source」合并到已有分组「Existing Merge Services」") // i18n-literal: Assert the Simplified Chinese merge step.
                XCTAssertEqual(plain(content.rows[1].detail),
                    "合并后「Merge Source」消失，「Existing Merge Services」共有 4 个凭证（其中 3 个对 Agent 隐藏）。合并无法自动撤销。") // i18n-literal: Assert the Simplified Chinese merge result.
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
            let details = FrozenOrganizationSummaryContent(summary: summary).rows.map { plain($0.detail) }
            XCTAssertEqual(details, language == "en"
                ? ["It has 2 credentials.", "The group is empty.",
                   "This group already exists, so nothing is created or changed. The group is empty."]
                : ["组里有 2 个凭证。", "组里没有凭证。", "这个分组已经存在，不会新建或改动任何内容。组里没有凭证。"]) // i18n-literal: Assert Simplified Chinese member counts.
            XCTAssertFalse(FrozenOrganizationSummaryContent(summary: BrokerOrganizationSummary(operations: [
                .createGroup("New"), .move(credential: "API", from: nil, to: "New"),
            ])).isDestructive)
        }
    }

    func testTwelveStepsAreNumberedAndCountedInTitleAndButton() {
        Fixtures.withLanguages { language in
            let content = FrozenOrganizationSummaryContent(summary: Fixtures.twelveSteps)
            XCTAssertEqual(content.rows.map(\.number), Array(1...12))
            let title = ApprovalPromptContent(request: Fixtures.request(.organize), credentialName: "credential-library",
                                              organizationSteps: content.rows.count).title
            XCTAssertFalse(title.contains("credential-library"))
            let primary = FrozenApprovalActions.primary(operation: .organize, steps: 12, destructive: content.isDestructive)
            XCTAssertEqual(primary.role, .destructive)
            if language == "en" {
                XCTAssertEqual(title, "Claude Code wants to reorganize your groups (12 steps)")
                XCTAssertEqual(primary.title, "Apply 12 Steps")
                XCTAssertEqual(plain(content.rows[1].title), "Move the credential “Service 2” from “Ungrouped” to “Group 1”")
            } else {
                XCTAssertEqual(title, "Claude Code 想调整分组（共 12 步）") // i18n-literal: Assert the Simplified Chinese organize title.
                XCTAssertEqual(primary.title, "执行这 12 步") // i18n-literal: Assert the Simplified Chinese organize button.
                XCTAssertEqual(plain(content.rows[1].title), "把凭证「Service 2」从「未分组」移到「Group 1」") // i18n-literal: Assert the Simplified Chinese move step.
            }
        }
    }

    func testPendingListUsesTheSameObjectNamingVerbs() {
        Fixtures.withLanguages { language in
            let sentences = [
                Fixtures.request(.read, display: Fixtures.display()), Fixtures.request(.read),
                Fixtures.request(.create), Fixtures.request(.modify), Fixtures.request(.delete), Fixtures.request(.organize),
            ].map { request in
                plain(PendingRequestPresentation(approval: BrokerPendingApproval(requestID: "request", capability: "capability",
                    request: request, trustedCredentialName: "Staging API")).sentence.plainText)
            }
            XCTAssertEqual(sentences, language == "en" ? [
                "Claude Code wants to use the credential “Staging API” to run ./deploy.sh --env staging",
                "Claude Code wants to use the credential “Staging API”",
                "Claude Code wants to create the credential “Staging API”",
                "Claude Code wants to change the credential “Staging API”",
                "Claude Code wants to delete the credential “Staging API”",
                "Claude Code wants to reorganize your groups",
            ] : [
                "Claude Code 想使用凭证「Staging API」运行 ./deploy.sh --env staging", // i18n-literal: Assert the Simplified Chinese pending sentence.
                "Claude Code 想使用凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese pending sentence.
                "Claude Code 想新建凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese pending sentence.
                "Claude Code 想修改凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese pending sentence.
                "Claude Code 想删除凭证「Staging API」", // i18n-literal: Assert the Simplified Chinese pending sentence.
                "Claude Code 想调整分组", // i18n-literal: Assert the Simplified Chinese pending sentence.
            ])
        }
    }
}
