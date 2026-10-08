import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

final class OrganizationApprovalContentTests: AskKeyAppTestCase {
    func testOrderedRowsShowGroupEffectsAndNonvisibleCountsInBothLanguages() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let summary = BrokerOrganizationSummary(operations: [.move(credential: "API", from: nil, to: "Staging"),
            .createGroup("New"), .renameGroup(from: "Old", to: "New", members: 4, nonvisible: 1),
            .deleteGroup(name: "Unused", members: 3, nonvisible: 2)])
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let rows = FrozenOrganizationSummaryContent(summary: summary).rows
            XCTAssertEqual(rows.count, 4)
            XCTAssertTrue(rows[0].title.hasPrefix("1. "))
            XCTAssertTrue(rows[0].title.contains("API"))
            XCTAssertTrue(rows[0].title.contains(appLocalized("Ungrouped")))
            XCTAssertTrue(rows[1].title.hasPrefix("2. "))
            XCTAssertEqual(rows[1].detail, appLocalized("New group — created when approved"))
            XCTAssertEqual(rows[2].detail, appLocalizedFormat("%lld credentials, %lld not visible to agents", 4, 1))
            XCTAssertEqual(rows[3].detail, appLocalizedFormat("%lld credentials, %lld not visible to agents", 3, 2))
            if language == "zh-Hans" {
                XCTAssertEqual(rows[2].title, "3. 重命名分组“Old” → “New”") // i18n-literal: Assert reviewed Simplified Chinese organization copy.
                XCTAssertEqual(rows[2].detail, "4 个凭证，其中 1 个 Agent 看不到") // i18n-literal: Assert reviewed Simplified Chinese organization copy.
                XCTAssertEqual(rows[3].detail, "3 个凭证，其中 2 个 Agent 看不到") // i18n-literal: Assert reviewed Simplified Chinese organization copy.
                XCTAssertEqual(appLocalized("Proposed organization"), "待执行的整理") // i18n-literal: Assert reviewed Simplified Chinese organization copy.
            }
            XCTAssertEqual(FrozenApprovalActions.titles(operation: .organize, timedAllowanceEnabled: true),
                [appLocalized("Approve Organization"), appLocalized("Deny")])
        }
    }

    func testRenameAndDeleteMemberCountsPluralizeAndOmitZeroNonvisibleInBothLanguages() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let cases = [
            (members: 0, nonvisible: 0, english: "0 credentials", chinese: "0 个凭证"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
            (members: 1, nonvisible: 0, english: "1 credential", chinese: "1 个凭证"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
            (members: 2, nonvisible: 0, english: "2 credentials", chinese: "2 个凭证"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
            (members: 1, nonvisible: 1, english: "1 credential, 1 not visible to agents", chinese: "1 个凭证，其中 1 个 Agent 看不到"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
            (members: 2, nonvisible: 1, english: "2 credentials, 1 not visible to agents", chinese: "2 个凭证，其中 1 个 Agent 看不到"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
            (members: 2, nonvisible: 2, english: "2 credentials, 2 not visible to agents", chinese: "2 个凭证，其中 2 个 Agent 看不到"), // i18n-literal: Assert reviewed Simplified Chinese member counts.
        ]
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            for testCase in cases {
                let summary = BrokerOrganizationSummary(operations: [
                    .renameGroup(from: "Old", to: "New", members: testCase.members, nonvisible: testCase.nonvisible),
                    .deleteGroup(name: "Unused", members: testCase.members, nonvisible: testCase.nonvisible),
                ])
                let rows = FrozenOrganizationSummaryContent(summary: summary).rows
                let expected = language == "en" ? testCase.english : testCase.chinese
                XCTAssertEqual(rows.map(\.detail), [expected, expected], "\(language), \(testCase.members) members, \(testCase.nonvisible) nonvisible")
            }
        }
    }

    @MainActor
    func testMaximumBatchAndExpandedDetailsKeepActionsWithin680PointsWithoutReveal() {
        _ = NSApplication.shared
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let request = BrokerApprovalOperationRequest(operationID: "synthetic", credentialID: "", targetID: "credential-library",
            operation: .organize, payloadDigest: String(repeating: "a", count: 64),
            callerName: "Synthetic Agent", callerPurpose: String(repeating: "Synthetic purpose ", count: 200), organizationCredentialIDs: [])
        let summary = BrokerOrganizationSummary(operations: (0..<64).map {
            .move(credential: "API \($0)", from: String(repeating: "Original group ", count: 15), to: "Staging")
        })
        var reveals = 0
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            for (expanded, cancelled) in [(false, false), (true, false), (true, true)] {
                let view = FrozenAgentApprovalPrompt(request: request, timedAllowanceEnabled: true,
                    organizationSummary: summary, revealMaterial: { reveals += 1; throw CancellationError() },
                    cancelledAuthenticationDecision: cancelled ? .once : nil,
                    detailsExpanded: expanded, finish: { _ in })
                let size = NSHostingView(rootView: view).fittingSize
                XCTAssertEqual(size.width, 300)
                XCTAssertLessThanOrEqual(size.height, 680, "Every operation scrolls with Approve and Deny outside the scrolling area")
            }
        }
        XCTAssertEqual(reveals, 0)
    }

    func testOrganizationPromptCopyOmitsCredentialTargetAndOffersWriteAuthenticationRetry() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            let request = BrokerApprovalOperationRequest(operationID: "synthetic", credentialID: "", targetID: "credential-library",
                operation: .organize, payloadDigest: String(repeating: "a", count: 64), callerName: "Synthetic Agent", organizationCredentialIDs: [])
            let content = ApprovalPromptContent(request: request, credentialName: "credential-library")
            XCTAssertEqual(content.title, language == "zh-Hans"
                ? "“Synthetic Agent”想整理凭证" // i18n-literal: Assert reviewed Simplified Chinese organization copy.
                : "“Synthetic Agent” wants to organize credentials")
            XCTAssertFalse(content.title.contains("credential-library"))
            XCTAssertNil(content.commandSummary)
            XCTAssertEqual(content.retryTitle, appLocalized("Authenticate and approve"))
            XCTAssertEqual(content.cancelledAuthenticationNote, appLocalized("You cancelled authentication. Nothing was changed, and the request is still pending."))
            let pending = BrokerPendingApproval(requestID: "request", capability: "capability", request: request)
            XCTAssertEqual(PendingRequestPresentation(approval: pending).sentence.plainText, language == "zh-Hans"
                ? "Synthetic Agent 想整理凭证" // i18n-literal: Assert reviewed Simplified Chinese organization copy.
                : "Synthetic Agent wants to organize credentials")
            XCTAssertFalse(PendingRequestPresentation(approval: pending).sentence.plainText.contains("credential-library"))
        }
    }
}
