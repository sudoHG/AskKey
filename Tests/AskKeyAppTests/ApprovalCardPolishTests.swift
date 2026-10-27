import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class ApprovalCardPolishTests: AskKeyAppTestCase {
    func testEnglishCopyDoesNotInheritChineseWrappingFromTheObservableStore() {
        let mode = AppLanguage.store.mode
        let current = AppLanguage.current
        defer { AppLanguage.apply(mode: mode); AppLanguage.current = current }
        AppLanguage.apply(mode: "zh-Hans")
        AppLanguage.current = "en"
        let purpose = "Deploy the staging site (not verified)"
        XCTAssertEqual(ApprovalCopy.wrapping(purpose), purpose)
    }

    func testProvidedValuesNameOnlyNewOrReplacedItems() {
        ApprovalCardFixtures.withLanguages { language in
            for (card, names) in [
                (ApprovalCardFixtures.Card.create, ["TOKEN", "CERT", "RECOVERY_CODE"]),
                (.modifySomeValues, ["TOKEN"]), (.modifyAdded, ["CERT"]),
            ] {
                let prompt = ApprovalCardFixtures.prompt(card)
                let value = prompt.presentation.details.rows.first { $0.value == .revealableValue }
                let format = names.count > 1 ? "%1$@ knows the values of %2$@."
                    : (card == .modifySomeValues ? "%1$@ knows the new %2$@ value." : "%1$@ knows the value of %2$@.")
                let list = language == "zh-Hans" && names.count == 3
                    ? "TOKEN、CERT 和 RECOVERY_CODE" : ApprovalCopy.list(names) // i18n-literal: Chinese name-list separators.
                XCTAssertEqual(value?.note?.plainText, appLocalizedFormat(format, "Claude Code", list))
                XCTAssertEqual(value?.note?.segments.filter(\.code).map(\.text), names)
                XCTAssertFalse(prompt.presentation.content.title.contains(value?.note?.plainText ?? "unexpected"))
            }
            for card in [ApprovalCardFixtures.Card.modifyMetadata, .modifyRemoved, .delete] {
                XCTAssertFalse(ApprovalCardFixtures.prompt(card).presentation.details.rows.contains { $0.value == .revealableValue })
            }
        }
    }

    func testInstructionEditsKeepContextAndUseMarksWithoutColor() {
        let before = "Use for release checks."
        let after = "Use only for the nightly release check."
        let diff = ApprovalTextDiff(before: before, after: after)
        let old = ApprovalDetailsView.attributed(diff.before)
        let new = ApprovalDetailsView.attributed(diff.after)
        XCTAssertEqual(String(old.characters), before)
        XCTAssertEqual(String(new.characters), after)
        XCTAssertTrue(old.runs.contains { $0.strikethroughStyle == .single })
        XCTAssertTrue(new.runs.contains { $0.underlineStyle == .single })
        XCTAssertFalse(new.runs.contains { $0.strikethroughStyle != nil })
        for run in new.runs where run.underlineStyle != nil {
            let text = String(new[run.range].characters)
            XCTAssertFalse(text.first?.isWhitespace == true)
            XCTAssertFalse(text.last?.isWhitespace == true)
        }
    }

    func testSimilarMovesKeepNamesStepNumbersAndOperationOrder() {
        let moves: [BrokerOrganizationSummary.Operation] = (1...12).map {
            .move(credential: "Service \($0)", from: "Old", to: "New")
        }
        let tail: [BrokerOrganizationSummary.Operation] = [
            .renameGroup(from: "New", to: "Renamed", members: 12, nonvisible: 0),
            .move(credential: "Tail", from: "Old", to: "New"),
            .move(credential: "Other", from: "Other", to: "New"),
        ]
        ApprovalCardFixtures.withLanguages { _ in
            let content = FrozenOrganizationSummaryContent(summary: .init(operations: moves + tail), requester: "Agent")
            XCTAssertEqual(content.rows.map(\.number), [1, 13, 14, 15])
            XCTAssertEqual(content.rows.map(\.lastNumber), [12, nil, nil, nil])
            XCTAssertEqual(content.rows[0].detail,
                (1...12).map { ApprovalCopy.quoted("Service \($0)") }.joined(separator: appLocalized("List separator")))
            XCTAssertEqual(content.subtitle, appLocalizedFormat("%lld steps", 15))
            XCTAssertTrue(content.rows[1].title.contains("Renamed"))
            XCTAssertTrue(content.rows[2].title.contains("Tail"))
            XCTAssertTrue(content.rows[3].title.contains("Other"))
        }
    }

    func testNamesAndTermsStayTogetherWithoutChangingTheCopy() {
        ApprovalCardFixtures.withLanguages { language in
            let text = ApprovalCardFixtures.copy(.create).title
            let wrapped = ApprovalCopy.wrapping(text)
            XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{2060}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " "), text)
            XCTAssertTrue(wrapped.contains("\u{2060}"))
            if language == "en" {
                let title = ApprovalCardFixtures.copy(.organize).title as NSString
                XCTAssertLessThanOrEqual(title.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)]).width,
                    FrozenAgentApprovalPrompt.contentWidth)
            }
            for card in [ApprovalCardFixtures.Card.modifyRemoved, .organizeExistingAndMerge, .organizeManyMoves] {
                let subtitle = ApprovalCardFixtures.copy(card).subtitle! as NSString
                XCTAssertLessThanOrEqual(subtitle.size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width,
                    FrozenAgentApprovalPrompt.contentWidth, "\(language): \(card)")
            }
            let phrases = language == "en" ? ["(2 hidden from agents)", "1 credential"]
                : ["组里有 1 个凭证", "合并后共 4 个凭证", "（2 个对 Agent 隐藏）"] // i18n-literal: Counted phrases.
            for phrase in phrases {
                XCTAssertEqual(ApprovalCopy.wrapping(phrase), ApprovalCopy.unbroken(phrase))
            }
        }
    }
}
