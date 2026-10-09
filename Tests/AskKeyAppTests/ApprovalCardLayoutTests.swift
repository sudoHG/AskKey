import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Every card keeps its actions on a 768-point screen: expanded details, and
/// names too long for the card, scroll inside the 640-point cap instead of
/// pushing the buttons away.
@MainActor
final class ApprovalCardLayoutTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func height(_ prompt: FrozenAgentApprovalPrompt) -> CGFloat {
        let size = Fixtures.host(prompt).fittingSize
        XCTAssertEqual(size.width, FrozenAgentApprovalPrompt.width)
        return size.height
    }

    private func details(_ prompt: FrozenAgentApprovalPrompt, expanded: Bool) -> FrozenAgentApprovalPrompt {
        var prompt = prompt
        prompt.detailsExpanded = expanded
        return prompt
    }

    func testEveryCardStaysWithinTheCapCollapsedAndExpanded() {
        XCTAssertEqual(FrozenAgentApprovalPrompt.maximumHeight, 640)
        Fixtures.withLanguages { language in
            for card in Fixtures.Card.allCases {
                let collapsed = height(details(Fixtures.prompt(card), expanded: false))
                XCTAssertLessThan(collapsed, 400, "\(language) \(card.rawValue): the front is one sentence and one line")
                XCTAssertLessThanOrEqual(height(details(Fixtures.prompt(card), expanded: true)), FrozenAgentApprovalPrompt.maximumHeight,
                                         "\(language) \(card.rawValue) with Details")
            }
        }
    }

    func testWriteCardsMatchTheReadCardLayout() {
        Fixtures.withLanguages { language in
            let read = height(Fixtures.prompt(.readWithoutTimed))
            for card in [Fixtures.Card.create, .delete, .modifyValue, .modifyMixed, .organize] {
                let write = height(Fixtures.prompt(card))
                XCTAssertLessThanOrEqual(abs(write - read), 20,
                    "\(language) \(card.rawValue): same icon, sentence, line, Details link, two buttons and footer")
            }
            XCTAssertLessThan(height(Fixtures.prompt(.createUngrouped)), read, "\(language): no line when ungrouped")
        }
    }

    func testExtremeContentScrollsInsideTheCapWithoutRevealingValues() {
        let long = String(repeating: "Guidance for the synthetic service. ", count: 110)
        let name = String(repeating: "Long Name ", count: 25)
        var reveals = 0
        let write = BrokerCredentialWriteSummary(credentialName: name, operation: .modify,
            before: (1...8).map { Fixtures.component("ITEM_\($0)", bytes: 10 + $0, .environmentVariable("VARIABLE_\($0)")) },
            after: (1...16).map { Fixtures.component("ITEM_\($0)", bytes: 20 + $0, .temporaryFile("PATH_\($0)")) },
            beforeDigest: "old", afterDigest: "new", beforeUsageInstructions: long, afterUsageInstructions: long + " Updated.",
            beforeGroup: name, afterGroup: name + "2", createsGroup: true)
        let organization = BrokerOrganizationSummary(operations: (0..<64).map { index in
            index.isMultiple(of: 2)
                ? .existingGroup(name: name, members: 1, nonvisible: 1)
                : .mergeGroup(from: name, to: name + "B", members: 4, nonvisible: 1, targetMembers: 2, targetNonvisible: 2)
        })
        let caller = String(repeating: "Synthetic Agent ", count: 250)
        func request(_ operation: BrokerApprovalOperation, display: BrokerApprovalOperationRequest.Display? = nil) -> BrokerApprovalOperationRequest {
            .init(operationID: "extreme", credentialID: "extreme", targetID: "extreme", operation: operation,
                  payloadDigest: String(repeating: "a", count: 64), credentialName: name, callerName: caller,
                  callerPurpose: long, display: display, organizationCredentialIDs: operation == .organize ? [] : nil)
        }
        let command = (1...200).map { "--flag-\($0)" }.joined(separator: " ")
        Fixtures.withLanguages { language in
            for expanded in [false, true] {
                for cancelled in [nil, BrokerApprovalDecision.once] {
                    let prompts: [FrozenAgentApprovalPrompt] = [
                        .init(request: request(.read, display: Fixtures.display(command: command)), timedAllowanceEnabled: true,
                              cancelledAuthenticationDecision: cancelled, detailsExpanded: expanded, finish: { _ in }),
                        .init(request: request(.modify), timedAllowanceEnabled: true, writeSummary: write,
                              revealMaterial: { reveals += 1; throw CancellationError() },
                              cancelledAuthenticationDecision: cancelled, detailsExpanded: expanded, finish: { _ in }),
                        .init(request: request(.organize), timedAllowanceEnabled: true, organizationSummary: organization,
                              cancelledAuthenticationDecision: cancelled, detailsExpanded: expanded, finish: { _ in }),
                    ]
                    for prompt in prompts {
                        XCTAssertEqual(height(prompt), FrozenAgentApprovalPrompt.maximumHeight, accuracy: 1,
                                       "\(language): long content scrolls inside the capped card")
                    }
                }
            }
        }
        XCTAssertEqual(reveals, 0, "laying out a card never asks to reveal a value")
    }

    func testDetailsExpandInPlaceAndTheCancelledStateAddsOneLine() {
        Fixtures.withLanguages { language in
            let collapsed = height(Fixtures.prompt(.readDefault))
            XCTAssertGreaterThan(height(Fixtures.prompt(.readDetails)), collapsed, "\(language): Details expand in place")
            let cancelled = height(Fixtures.prompt(.readCancelled)) - collapsed
            XCTAssertGreaterThan(cancelled, 10, "\(language): the gray line is added")
            XCTAssertLessThan(cancelled, 2 * 16 + Theme.Spacing.md, "\(language): and no button is added or removed")
            XCTAssertLessThan(height(Fixtures.prompt(.readWithoutTimed)), collapsed)
        }
    }

    func testScrollingPartsGiveUpHeightInOrder() {
        func heights(_ maximum: CGFloat) -> CGFloat {
            NSHostingView(rootView: ApprovalCardLayout(maximumHeight: maximum) {
                Color.clear.frame(height: 100)
                ScrollView { Color.clear.frame(height: 200) }
                    .layoutValue(key: ApprovalCardFlexibleKey.self, value: 2)
                ScrollView { Color.clear.frame(height: 300) }
                    .layoutValue(key: ApprovalCardFlexibleKey.self, value: 1)
            }
            .frame(width: FrozenAgentApprovalPrompt.contentWidth)
            .fixedSize(horizontal: false, vertical: true)).fittingSize.height
        }
        XCTAssertEqual(heights(700), 600, accuracy: 1, "a card that fits keeps its natural height")
        XCTAssertEqual(heights(500), 500, accuracy: 1, "Details scroll first")
        XCTAssertEqual(heights(300), 300, accuracy: 1, "then the title, once Details are at their minimum")
    }
}
