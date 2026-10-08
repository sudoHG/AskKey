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
            XCTAssertEqual(FrozenApprovalActions.titles(operation: .organize, timedAllowanceEnabled: true),
                [appLocalized("Approve Organization"), appLocalized("Deny")])
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
            XCTAssertFalse(content.title.contains("credential-library"))
            XCTAssertNil(content.commandSummary)
            XCTAssertEqual(content.retryTitle, appLocalized("Authenticate and approve"))
            XCTAssertEqual(content.cancelledAuthenticationNote, appLocalized("You cancelled authentication. Nothing was changed, and the request is still pending."))
            let pending = BrokerPendingApproval(requestID: "request", capability: "capability", request: request)
            XCTAssertFalse(PendingRequestPresentation(approval: pending).sentence.plainText.contains("credential-library"))
        }
    }
}
