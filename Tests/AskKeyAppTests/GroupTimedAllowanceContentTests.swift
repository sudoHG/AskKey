import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

@MainActor
final class GroupTimedAllowanceContentTests: AskKeyAppTestCase {
    static let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    static var snapshot: BrokerGroupAllowanceSnapshot {
        .init(groupName: "Synthetic Project", members: [
            .init(credentialID: "alpha", name: "Synthetic API", metadataDigest: String(repeating: "a", count: 64)),
            .init(credentialID: "beta", name: "Synthetic Certificate", metadataDigest: String(repeating: "b", count: 64), expiresAt: expiry)
        ])
    }

    func testBothLanguagesShowEveryMemberAndEarlierExpiryOnlyInDetails() {
        ApprovalCardFixtures.withLanguages { language in
            let state = GroupTimedAllowancePresentation(snapshot: Self.snapshot)
            let request = ApprovalCardFixtures.request(.read, display: ApprovalCardFixtures.display())
            let normal = FrozenAgentApprovalPrompt(request: request, timedAllowanceEnabled: true, finish: { _ in }).presentation
            let group = FrozenAgentApprovalPrompt(request: request, timedAllowanceEnabled: true,
                                                 groupAllowance: state, finish: { _ in }).presentation
            XCTAssertEqual(group.content, normal.content, "Group scope must not expand the front")
            XCTAssertEqual(group.buttons.map(\.decision), [.once, .timedAllow(duration: 1_800), .timedAllowGroup(duration: 1_800), .deny])
            let button = group.buttons[2]
            XCTAssertEqual(button.title, language == "en" ? "Allow Group for 30 Minutes" : "允许整个分组 30 分钟") // i18n-literal: Chinese group action.
            let names = group.details.rows.compactMap { row -> [String]? in
                guard case .lines(let lines) = row.value, lines.map({ $0.text.plainText }) == Self.snapshot.members.map(\.name) else { return nil }
                return lines.map { $0.text.plainText }
            }
            XCTAssertEqual(names, [Self.snapshot.members.map(\.name)])
            XCTAssertEqual(group.details.rows.last?.label, language == "en" ? "Group deadline" : "授权期限") // i18n-literal: Chinese deadline label.
            guard case .text(let deadline) = group.details.rows.last?.value else { return XCTFail("Missing shared deadline") }
            XCTAssertTrue(deadline.contains(language == "en" ? "whichever comes first" : "以较早者为准")) // i18n-literal: Chinese expiry explanation.
        }
    }

    func testWithdrawingGroupOptionPreservesSingleOptionsAndSubject() {
        let state = GroupTimedAllowancePresentation(snapshot: Self.snapshot)
        let prompt = FrozenAgentApprovalPrompt(request: ApprovalCardFixtures.request(.read), timedAllowanceEnabled: true,
                                              groupAllowance: state, finish: { _ in })
        let before = prompt.presentation
        state.snapshot = nil
        let after = prompt.presentation
        XCTAssertEqual(before.content, after.content)
        XCTAssertEqual(after.buttons.map(\.decision), [.once, .timedAllow(duration: 1_800), .deny])
        XCTAssertFalse(after.details.rows.contains { $0.label == appLocalized("Group allowance") })
    }

    func testDisabledUngroupedAndWriteCardsNeverOfferGroupAllowance() {
        for operation in [BrokerApprovalOperation.read, .create, .modify, .delete, .organize] {
            for enabled in [false, true] {
                let buttons = FrozenApprovalActions.buttons(operation: operation, timedAllowanceEnabled: enabled,
                    groupSnapshot: Self.snapshot)
                XCTAssertEqual(buttons.contains { $0.identifier == "approval-allow-group-timed" }, operation == .read && enabled)
            }
        }
        XCTAssertFalse(FrozenApprovalActions.buttons(operation: .read, timedAllowanceEnabled: true).contains {
            $0.identifier == "approval-allow-group-timed"
        })
    }
}
