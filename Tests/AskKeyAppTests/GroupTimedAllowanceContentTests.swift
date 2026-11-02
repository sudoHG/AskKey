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
            XCTAssertEqual(button.title, language == "en" ? "Allow Group for 30 Minutes (2 credentials)" : "允许整个分组 30 分钟（2 个凭证）") // i18n-literal: Chinese group action.
            XCTAssertTrue(group.details.rows.contains { $0.label == (language == "en" ? "Entire group" : "整个分组") }) // i18n-literal: Chinese group scope label.
            let names = group.details.rows.compactMap { row -> [String]? in
                guard case .lines(let lines) = row.value, lines.map({ $0.text.plainText }) == Self.snapshot.members.map(\.name) else { return nil }
                return lines.map { $0.text.plainText }
            }
            XCTAssertEqual(names, [Self.snapshot.members.map(\.name)])
            XCTAssertEqual(group.details.rows.last?.label, language == "en" ? "Expires" : "到期时间") // i18n-literal: Chinese deadline label.
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
        XCTAssertFalse(after.details.rows.contains { $0.label == appLocalized("Entire group") })
    }

    func testGroupButtonUsesTheFrozenMemberCountAndSingularCopy() {
        ApprovalCardFixtures.withLanguages { language in
            for count in [1, 2, 12] {
                let snapshot = BrokerGroupAllowanceSnapshot(groupName: "Project", members: (1...count).map {
                    .init(credentialID: "id-\($0)", name: "Credential \($0)", metadataDigest: String(repeating: "a", count: 64))
                })
                let buttons = FrozenApprovalActions.buttons(operation: .read, timedAllowanceEnabled: true,
                                                             minutes: 120, groupSnapshot: snapshot)
                let noun = count == 1 ? "credential" : "credentials"
                XCTAssertEqual(buttons[2].title, language == "en"
                    ? "Allow Group for 120 Minutes (\(count) \(noun))"
                    : "允许整个分组 120 分钟（\(count) 个凭证）") // i18n-literal: Chinese counted group action.
            }
        }
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
