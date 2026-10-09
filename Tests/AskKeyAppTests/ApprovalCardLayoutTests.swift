import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

/// Every card keeps its actions on a 768-point screen: the body scrolls, with
/// a visible scroll bar and an overflow line, instead of pushing them away.
@MainActor
final class ApprovalCardLayoutTests: AskKeyAppTestCase {
    private typealias Fixtures = ApprovalCardFixtures

    private func height(_ prompt: FrozenAgentApprovalPrompt) -> CGFloat {
        let size = Fixtures.host(prompt).fittingSize
        XCTAssertEqual(size.width, FrozenAgentApprovalPrompt.width)
        return size.height
    }

    func testEveryCardTypeStaysWithinTheCapInBothLanguages() {
        XCTAssertLessThanOrEqual(FrozenAgentApprovalPrompt.maximumHeight, 680)
        Fixtures.withLanguages { language in
            for card in Fixtures.Card.allCases {
                XCTAssertLessThanOrEqual(height(Fixtures.prompt(card)), FrozenAgentApprovalPrompt.maximumHeight,
                                         "\(language) \(card.rawValue)")
            }
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

    func testCommandsOverFourLinesScrollWithAnOverflowLine() {
        func read(lines: Int) -> FrozenAgentApprovalPrompt {
            let command = (1...lines).map { "./step-\($0).sh" }.joined(separator: "\n")
            return .init(request: Fixtures.request(.read, display: Fixtures.display(command: command)),
                         timedAllowanceEnabled: true, finish: { _ in })
        }
        Fixtures.withLanguages { language in
            let one = height(read(lines: 1))
            let four = height(read(lines: 4))
            let five = height(read(lines: 5))
            let thirty = height(read(lines: 30))
            XCTAssertEqual(four - one, 3 * FrozenAgentApprovalPrompt.commandLineHeight, accuracy: 3,
                           "\(language): up to four lines show in full")
            XCTAssertGreaterThan(five, four, "\(language): the overflow line appears under a capped command")
            XCTAssertLessThan(five - four, FrozenAgentApprovalPrompt.commandLineHeight + 6,
                              "\(language): the fifth line scrolls instead of growing the card")
            XCTAssertEqual(thirty, five, accuracy: 1, "\(language): longer commands keep the same cap")
        }
    }

    func testDetailsGrowTheReadCardAndTheCancelledStateDropsTheTimedAction() {
        Fixtures.withLanguages { language in
            let collapsed = height(Fixtures.prompt(.readDefault))
            XCTAssertGreaterThan(height(Fixtures.prompt(.readDetails)), collapsed, "\(language): Details expand in place")
            XCTAssertLessThan(height(Fixtures.prompt(.readCancelled)), collapsed, "\(language): one retry replaces two allow buttons")
            XCTAssertLessThan(height(Fixtures.prompt(.readWithoutTimed)), collapsed)
        }
    }
}
