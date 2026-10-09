import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Details are one list of label and value rows, in a fixed order per card,
/// that never repeats the title or subtitle.
@MainActor
final class ApprovalDetailsContentTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures
    private typealias Card = ApprovalCardFixtures.Card

    private func rows(_ card: Card) -> [ApprovalDetailsContent.Row] {
        Fixtures.prompt(card).presentation.details.rows
    }

    private func labels(_ card: Card) -> [String] {
        rows(card).map(\.label)
    }

    /// The row as plain text: tags lead their line, notes follow on the next.
    private func text(_ value: ApprovalDetailsContent.Value) -> String {
        switch value {
        case .text(let text), .code(let text): return text
        case .lines(let lines):
            return lines.map { line in
                (line.tag.map { $0.title + " " } ?? "") + line.text.plainText + (line.note.map { "\n" + $0 } ?? "")
            }.joined(separator: "\n")
        case .diff(let diff): return "diff: " + diff.removedPhrases.joined(separator: ", ")
        case .revealableValue: return "••••••"
        }
    }

    private func values(_ card: Card) -> [String] {
        rows(card).map { text($0.value) }
    }

    func testReadRowsInBothLanguages() {
        Fixtures.withLanguages { language in
            let scope = FrozenApprovalActions.timedScope(minutes: 30)
            if language == "en" {
                XCTAssertEqual(labels(.readDefault), ["Requested by", "Purpose", "Command", "Runs in", "Hands over", "30 minutes"])
                XCTAssertEqual(values(.readDefault), ["Claude Code (not verified)", "Deploy the staging site (not verified)",
                    "./deploy.sh --env staging", "~/web", "Staging API → environment variable STAGING_API_TOKEN", scope])
                XCTAssertEqual(values(.readFile)[4], "Staging API → temporary file STAGING_CERT_FILE")
                XCTAssertEqual(values(.readBundle)[4],
                    "The items of “Staging API” that are set to be given to programs (names are shown after you approve)")
            } else {
                XCTAssertEqual(labels(.readDefault), ["请求方", "用途", "命令", "运行目录", "交出", "30 分钟"]) // i18n-literal: Chinese read labels.
                XCTAssertEqual(values(.readDefault), ["Claude Code（未核实）", "Deploy the staging site（未核实）", // i18n-literal: Chinese read values.
                    "./deploy.sh --env staging", "~/web", "Staging API → 环境变量 STAGING_API_TOKEN", scope]) // i18n-literal: Chinese read values.
                XCTAssertEqual(values(.readFile)[4], "Staging API → 临时文件 STAGING_CERT_FILE") // i18n-literal: Chinese file row.
                XCTAssertEqual(values(.readBundle)[4], "“Staging API”里设为交给程序的所有项（具体名称批准后才能看到）") // i18n-literal: Chinese bundle row.
            }
            XCTAssertEqual(rows(.readDefault)[2].value, .code("./deploy.sh --env staging"), "the command is monospaced")
            XCTAssertEqual(rows(.readDefault)[3].value, .code("~/web"))
            XCTAssertEqual(labels(.readWithoutTimed).count, 5, "no timed row without the timed option")
            let command = "./deploy.sh " + (1...30).map { "--flag-\($0) value" }.joined(separator: " ")
            let long = ApprovalDetailsContent(request: Fixtures.request(.read, display: Fixtures.display(command: command)),
                                              credentialName: "Staging API")
            XCTAssertEqual(long.rows[2].value, .code(command), "Details show the whole command")
        }
    }

    func testCreateRowsInBothLanguages() {
        Fixtures.withLanguages { language in
            if language == "en" {
                XCTAssertEqual(labels(.create), ["Requested by", "Purpose", "Contents", "Instructions", "Value"])
                XCTAssertEqual(values(.create)[2], [
                    "TOKEN · given to programs as environment variable RELEASE_CHECK_TOKEN",
                    "CERT · given to programs as a temporary file (path in RELEASE_CERT_FILE)",
                    "RECOVERY_CODE · kept in Ask Key only, never given to agents",
                ].joined(separator: "\n"))
            } else {
                XCTAssertEqual(labels(.create), ["请求方", "用途", "内容", "说明", "值"]) // i18n-literal: Chinese create labels.
                XCTAssertEqual(values(.create)[2], [
                    "TOKEN · 使用时作为环境变量 RELEASE_CHECK_TOKEN 交给程序", // i18n-literal: Chinese create item.
                    "CERT · 使用时作为临时文件交给程序（路径在 RELEASE_CERT_FILE）", // i18n-literal: Chinese create item.
                    "RECOVERY_CODE · 只存在请旨里，不交给任何 Agent", // i18n-literal: Chinese create item.
                ].joined(separator: "\n"))
            }
            XCTAssertEqual(values(.create)[3], "Use only for the release smoke check. Keep values out of logs.")
            XCTAssertEqual(rows(.create)[4].value, .revealableValue)
            guard case .lines(let items) = rows(.create)[2].value else { return XCTFail("Expected item lines") }
            XCTAssertEqual(items.first?.text.segments.filter(\.code).map(\.text), ["TOKEN", "RELEASE_CHECK_TOKEN"])
            XCTAssertEqual(labels(.createUngrouped).count, 4, "no instructions row when there are none")
        }
    }

    func testChangeRowsListOnlyWhatChanges() {
        Fixtures.withLanguages { language in
            let requester = language == "en" ? ["Requested by", "Purpose"] : ["请求方", "用途"] // i18n-literal: Chinese labels.
            let changes = language == "en" ? "Changes" : "改动" // i18n-literal: Chinese label.
            let instructions = language == "en" ? "Instructions" : "说明" // i18n-literal: Chinese label.
            let group = language == "en" ? "Group" : "分组" // i18n-literal: Chinese label.
            let value = language == "en" ? "Value" : "值" // i18n-literal: Chinese label.
            XCTAssertEqual(labels(.modifyMetadata), requester + [instructions])
            XCTAssertEqual(values(.modifyMetadata)[2], "diff: checks", "the diff names what was deleted")
            XCTAssertEqual(labels(.modifyInstructionsAndGroup), requester + [instructions, group])
            XCTAssertEqual(values(.modifyInstructionsAndGroup)[3], "“Release Tools” → “Operations”")
            XCTAssertEqual(labels(.modifyValue), requester + [changes, value])
            XCTAssertEqual(labels(.modifySomeValues), requester + [changes, value])
            XCTAssertEqual(labels(.modifyAdded), requester + [changes, value])
            XCTAssertEqual(labels(.modifyRemoved), requester + [changes])
            XCTAssertEqual(labels(.modifyMixed), requester + [changes, group, value])
            XCTAssertEqual([values(.modifySomeValues)[2], values(.modifyAdded)[2], values(.modifyRemoved)[2]], language == "en"
                ? ["Replaced TOKEN", "New CERT", "Removed USER"] : ["替换 TOKEN", "新增 CERT", "移除 USER"]) // i18n-literal: Chinese change rows.
            let newGroup = BrokerCredentialWriteSummary(credentialName: "Release Check", operation: .modify,
                before: [Fixtures.token], after: [Fixtures.token], beforeDigest: "same", afterDigest: "same",
                beforeGroup: "Release Tools", afterGroup: "Operations", createsGroup: true)
            XCTAssertEqual(values(Fixtures.write(.modify, newGroup).presentation.details.rows).last, language == "en"
                ? "“Release Tools” → “Operations” (new group)" : "“Release Tools” → “Operations”（新分组）") // i18n-literal: Chinese new group.
        }
    }

    private func values(_ rows: [ApprovalDetailsContent.Row]) -> [String] {
        rows.map { text($0.value) }
    }

    func testDeleteAndOrganizeRowsInBothLanguages() {
        Fixtures.withLanguages { language in
            XCTAssertEqual(labels(.delete), language == "en"
                ? ["Requested by", "Purpose", "Contents"] : ["请求方", "用途", "内容"]) // i18n-literal: Chinese delete labels.
            XCTAssertEqual(values(.delete)[2], "TOKEN\nUSER")
            XCTAssertEqual(labels(.organize), language == "en"
                ? ["Requested by", "Purpose", "Step 1", "Step 2", "Step 3", "Step 4"]
                : ["请求方", "用途", "第 1 步", "第 2 步", "第 3 步", "第 4 步"]) // i18n-literal: Chinese organize labels.
            XCTAssertEqual(values(.organize)[2], language == "en"
                ? "Create the group “Staging Services”" : "新建分组“Staging Services”") // i18n-literal: Chinese organize step.
            XCTAssertEqual(values(.organizeExistingAndMerge)[2], language == "en"
                ? "No change Create the group “Existing Private Services”\nThis group already exists, so nothing is created or changed. It has 1 credential (1 hidden from agents)."
                : "无变化 新建分组“Existing Private Services”\n这个分组已经存在，不会新建或改动任何内容。组里有 1 个凭证（其中 1 个对 Agent 隐藏）。") // i18n-literal: Chinese organize step.
            XCTAssertEqual(labels(.organizeTwelveSteps).count, 14)
        }
    }

    func testDetailsNeverRepeatTheTitleOrSubtitle() {
        Fixtures.withLanguages { language in
            for card in Card.allCases {
                let copy = Fixtures.copy(card)
                for value in values(card) {
                    XCTAssertNotEqual(value, copy.title, "\(language) \(card.rawValue)")
                    if let subtitle = copy.subtitle {
                        XCTAssertFalse(value.contains(subtitle), "\(language) \(card.rawValue): \(value)")
                    }
                }
                XCTAssertFalse(labels(card).contains(language == "en" ? "After you approve" : "批准后"), // i18n-literal: Chinese label.
                               "\(language) \(card.rawValue)")
            }
        }
    }

    func testWriteWithoutASummaryStillOffersTheValue() {
        let request = Fixtures.request(.create)
        let details = ApprovalDetailsContent(request: request, credentialName: "Staging API")
        XCTAssertEqual(details.rows.last?.value, .revealableValue)
        XCTAssertEqual(ApprovalDetailsContent(request: Fixtures.request(.delete), credentialName: "Staging API").rows.count, 2)
    }

    func testOneLabelColumnForEveryCard() {
        Fixtures.withLanguages { language in
            let width = ApprovalDetailsContent.labelWidth()
            XCTAssertGreaterThan(width, 30)
            XCTAssertLessThan(width, 100, "\(language): values keep most of the card's width")
        }
    }
}
