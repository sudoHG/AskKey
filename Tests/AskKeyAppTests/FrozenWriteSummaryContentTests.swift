import CryptoKit
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit
@testable import AskKeyVault

/// Write cards: exact per-item tags, what counts as a value-only or
/// irreversible change, the instruction diff, and the subtitle.
@MainActor
final class FrozenWriteSummaryContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func content(_ summary: BrokerCredentialWriteSummary) -> FrozenWriteSummaryContent {
        FrozenWriteSummaryContent(summary: summary, requester: "Claude Code")
    }

    private func modification(before: [BrokerCredentialComponentSummary], after: [BrokerCredentialComponentSummary],
                              beforeDigest: String? = "old", afterDigest: String? = "new") -> BrokerCredentialWriteSummary {
        .init(credentialName: "Release Check", operation: .modify, before: before, after: after,
              beforeDigest: beforeDigest, afterDigest: afterDigest, beforeUsageInstructions: "Use for release checks.",
              afterUsageInstructions: "Use for release checks.", beforeGroup: "Release Tools", afterGroup: "Release Tools")
    }

    func testCreateCarriesEveryItemAndItsInstructions() {
        let create = content(Fixtures.createSummary)
        XCTAssertEqual(create.components.map(\.name), ["TOKEN", "CERT", "RECOVERY_CODE"])
        XCTAssertEqual(create.components.map(\.tag), [nil, nil, nil], "create rows carry no status tags")
        XCTAssertEqual(create.valueComponents.map(\.name), ["TOKEN", "CERT", "RECOVERY_CODE"])
        XCTAssertEqual(create.instructions, "Use only for the release smoke check. Keep values out of logs.")
        XCTAssertNil(create.groupChange, "the subtitle names the group")
        XCTAssertFalse(create.isDestructive)
    }

    func testMetadataOnlyChangeLeavesEveryItemUnchanged() {
        let modify = content(Fixtures.metadataSummary)
        XCTAssertEqual(modify.components.map(\.tag), [.unchanged, .unchanged])
        XCTAssertTrue(modify.changedComponents.isEmpty)
        XCTAssertTrue(modify.valueComponents.isEmpty)
        XCTAssertNotNil(modify.instructionsDiff)
        XCTAssertNil(modify.groupChange)
        XCTAssertFalse(modify.valueOnlyChange)
        XCTAssertFalse(modify.isDestructive)
    }

    func testValueOnlyChangeIsIrreversible() {
        let modify = content(Fixtures.valueSummary)
        XCTAssertTrue(modify.valueOnlyChange)
        XCTAssertTrue(modify.isDestructive)
        XCTAssertEqual(modify.changedComponents.map(\.tag), [.replaced])
        XCTAssertEqual(modify.valueComponents.map(\.name), ["TOKEN"])
        XCTAssertNil(modify.instructionsDiff)
    }

    func testAddedItemLosesNothing() {
        let modify = content(Fixtures.addedSummary)
        XCTAssertEqual(modify.components.map(\.tag), [.unchanged, .unchanged, .new])
        XCTAssertEqual(modify.changedComponents.map(\.name), ["CERT"])
        XCTAssertEqual(modify.valueComponents.map(\.name), ["CERT"], "only the new value can be viewed")
        XCTAssertFalse(modify.valueOnlyChange)
        XCTAssertFalse(modify.isDestructive)
    }

    func testGroupChangeNamesBothGroupsAndANewGroup() {
        Fixtures.withLanguages { language in
            let moved = content(Fixtures.instructionsAndGroupSummary).groupChange
            XCTAssertEqual(moved, .init(before: "“Release Tools”", after: "“Operations”", createsGroup: false))
            let ungrouped = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
                before: [Fixtures.token], after: [Fixtures.token], beforeDigest: "same", afterDigest: "same",
                beforeGroup: nil, afterGroup: "Operations", createsGroup: true)
            XCTAssertEqual(content(ungrouped).groupChange, .init(before: language == "en" ? "“Ungrouped”" : "“未分组”", // i18n-literal: Chinese ungrouped name.
                                                                 after: "“Operations”", createsGroup: true))
        }
    }

    func testDeleteListsTheItemsAndLosesNothing() {
        let delete = content(Fixtures.deleteSummary)
        XCTAssertEqual(delete.components.map(\.name), ["TOKEN", "USER"])
        XCTAssertEqual(delete.components.map(\.tag), [nil, nil])
        XCTAssertTrue(delete.valueComponents.isEmpty)
        XCTAssertNil(delete.subtitle, "the card states the Recycle Bin for every delete")
        XCTAssertFalse(delete.isDestructive, "a deleted credential can be restored")
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
        XCTAssertEqual(changed.changedComponents.map(\.name), ["TOKEN", "USER"])
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
        XCTAssertEqual(diff.merged.map(\.kind), [.same, .added, .same, .added, .same, .removed, .same])
        XCTAssertEqual(diff.merged.filter { $0.kind != .added }.map(\.text).joined(), diff.before.map(\.text).joined())
        XCTAssertEqual(diff.merged.filter { $0.kind != .removed }.map(\.text).joined(), diff.after.map(\.text).joined())
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
