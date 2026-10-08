import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

final class FrozenWriteSummaryContentTests: AskKeyAppTestCase {
    private typealias Row = FrozenWriteSummaryContent.Row

    private struct Copy {
        let before: String
        let after: String
        let unchanged: String
        let none: String
        let ungrouped: String
    }

    private func withLanguages(_ assertion: (Copy) -> Void) {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let fixtures = [
            ("en", Copy(before: "Before", after: "After", unchanged: "Unchanged", none: "None", ungrouped: "Ungrouped")),
            ("zh-Hans", Copy(before: "修改前", after: "修改后", unchanged: "不变", none: "无", ungrouped: "未分组")), // i18n-literal: Assert localized write summary rows.
        ]
        for (language, copy) in fixtures {
            AppLanguage.current = language
            assertion(copy)
        }
    }

    private func component(_ byteCount: Int = 24) -> BrokerCredentialComponentSummary {
        .init(name: "token", payloadKind: .text, byteCount: byteCount,
            delivery: .environmentVariable("STAGING_TOKEN"), masked: true)
    }

    private func modification(beforeDigest: String? = "same", afterDigest: String? = "same",
        afterBytes: Int = 24, beforeInstructions: String? = "Original guidance", afterInstructions: String? = "Original guidance",
        beforeGroup: String? = "Staging", afterGroup: String? = "Staging") -> BrokerCredentialWriteSummary {
        .init(credentialName: "Staging API", operation: .modify, before: [component()], after: [component(afterBytes)],
            beforeDigest: beforeDigest, afterDigest: afterDigest, beforeUsageInstructions: beforeInstructions,
            afterUsageInstructions: afterInstructions, beforeGroup: beforeGroup, afterGroup: afterGroup)
    }

    func testCreateShowsOnlyValuesToWriteWithoutComparisonLabels() {
        withLanguages { _ in
            let summary = BrokerCredentialWriteSummary(credentialName: "Staging API", operation: .create,
                before: [], after: [component()], beforeDigest: nil, afterDigest: "new",
                beforeUsageInstructions: nil, afterUsageInstructions: "New guidance",
                beforeGroup: nil, afterGroup: "New Services", createsGroup: true)
            let content = FrozenWriteSummaryContent(summary: summary)
            XCTAssertEqual(content.components, [Row(label: nil, values: ["token · 24 B · STAGING_TOKEN"])])
            XCTAssertEqual(content.instructions, [Row(label: nil, values: ["New guidance"])])
            XCTAssertEqual(content.group, [Row(label: nil, values: ["New Services"])])
            XCTAssertTrue(content.createsGroup)
        }
    }

    func testDeleteShowsOnlyCurrentValuesWithoutComparisonLabels() {
        withLanguages { _ in
            let summary = BrokerCredentialWriteSummary(credentialName: "Staging API", operation: .delete,
                before: [component()], after: [], beforeDigest: "current", afterDigest: nil,
                beforeUsageInstructions: "Current guidance", afterUsageInstructions: nil,
                beforeGroup: "Current Services", afterGroup: nil)
            let content = FrozenWriteSummaryContent(summary: summary)
            XCTAssertEqual(content.components, [Row(label: nil, values: ["token · 24 B · STAGING_TOKEN"])])
            XCTAssertEqual(content.instructions, [Row(label: nil, values: ["Current guidance"])])
            XCTAssertEqual(content.group, [Row(label: nil, values: ["Current Services"])])
            XCTAssertFalse(content.createsGroup)
        }
    }

    func testMetadataOnlyModifyShowsUnchangedComponentsAndGroupOnce() {
        withLanguages { copy in
            let content = FrozenWriteSummaryContent(summary: modification(afterInstructions: "New guidance"))
            XCTAssertEqual(content.components, [Row(label: copy.unchanged, values: ["token · 24 B · STAGING_TOKEN"])])
            XCTAssertEqual(content.instructions, [Row(label: copy.before, values: ["Original guidance"]),
                                                  Row(label: copy.after, values: ["New guidance"])])
            XCTAssertEqual(content.group, [Row(label: copy.unchanged, values: ["Staging"])])
            XCTAssertFalse(content.createsGroup)
        }
    }

    func testValueOnlyModifyShowsUnchangedMetadataOnce() {
        withLanguages { copy in
            let content = FrozenWriteSummaryContent(summary: modification(beforeDigest: "old", afterDigest: "new", afterBytes: 25))
            XCTAssertEqual(content.components, [Row(label: copy.before, values: ["token · 24 B · STAGING_TOKEN"]),
                                                Row(label: copy.after, values: ["token · 25 B · STAGING_TOKEN"])])
            XCTAssertEqual(content.instructions, [Row(label: copy.unchanged, values: ["Original guidance"])])
            XCTAssertEqual(content.group, [Row(label: copy.unchanged, values: ["Staging"])])
        }
    }

    func testClearingMetadataShowsEmptyInstructionAndUngroupedAfterValues() {
        withLanguages { copy in
            let content = FrozenWriteSummaryContent(summary: modification(afterInstructions: "", afterGroup: nil))
            XCTAssertEqual(content.components, [Row(label: copy.unchanged, values: ["token · 24 B · STAGING_TOKEN"])])
            XCTAssertEqual(content.instructions, [Row(label: copy.before, values: ["Original guidance"]),
                                                  Row(label: copy.after, values: [copy.none])])
            XCTAssertEqual(content.group, [Row(label: copy.before, values: ["Staging"]),
                                           Row(label: copy.after, values: [copy.ungrouped])])
        }
    }

    func testSameLengthValueReplacementIsNotLabeledUnchanged() {
        withLanguages { copy in
            let content = FrozenWriteSummaryContent(summary: modification(beforeDigest: "old-value", afterDigest: "new-value"))
            XCTAssertEqual(content.components, [Row(label: copy.before, values: ["token · 24 B · STAGING_TOKEN"]),
                                                Row(label: copy.after, values: ["token · 24 B · STAGING_TOKEN"])])
        }
    }

    func testMissingValueDigestsDoNotClaimComponentsAreUnchanged() {
        withLanguages { copy in
            let content = FrozenWriteSummaryContent(summary: modification(beforeDigest: nil, afterDigest: nil))
            XCTAssertEqual(content.components.map(\.label), [copy.before, copy.after])
        }
    }
}
