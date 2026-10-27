import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class ApprovalCardPolishTests: AskKeyAppTestCase {
    func testProvidedValuesNameOnlyNewOrReplacedItems() {
        ApprovalCardFixtures.withLanguages { _ in
            for (card, names) in [
                (ApprovalCardFixtures.Card.create, ["TOKEN", "CERT", "RECOVERY_CODE"]),
                (.modifySomeValues, ["TOKEN"]), (.modifyAdded, ["CERT"]),
            ] {
                let prompt = ApprovalCardFixtures.prompt(card)
                let value = prompt.presentation.details.rows.first { $0.value == .revealableValue }
                XCTAssertEqual(value?.note, appLocalizedFormat("Already known to %1$@: %2$@.", "Claude Code",
                    ApprovalCopy.list(names.map(ApprovalCopy.quoted))))
                XCTAssertFalse(prompt.presentation.content.title.contains(value?.note ?? "unexpected"))
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

    func testChineseTermsStayTogetherWithoutChangingTheCopy() {
        ApprovalCardFixtures.withLanguages { language in
            let text = ApprovalCardFixtures.copy(.create).title
            let wrapped = ApprovalCopy.wrapping(text)
            XCTAssertEqual(wrapped.replacingOccurrences(of: "\u{2060}", with: ""), text)
            XCTAssertEqual(wrapped.contains("\u{2060}"), language == "zh-Hans")
        }
    }
}
