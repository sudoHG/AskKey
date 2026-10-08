import AppKit
import SwiftUI
import XCTest
import AskKeyBroker
@testable import AskKeyAppKit

final class ApprovalMetadataContentTests: AskKeyAppTestCase {
    func testApprovalMetadataCopyInEnglishAndSimplifiedChinese() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "en"
        XCTAssertEqual(appLocalized("Usage instructions"), "Usage instructions")
        XCTAssertEqual(appLocalized("Group"), "Group")
        XCTAssertEqual(appLocalized("New group — created when approved"), "New group — created when approved")
        XCTAssertEqual(appLocalized("None"), "None")
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(appLocalized("Usage instructions"), "使用说明") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("Group"), "分组") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("New group — created when approved"), "新分组 · 批准后创建") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("None"), "无") // i18n-literal: Assert Simplified Chinese metadata approval copy.
    }

    @MainActor
    func testFullMetadataFitsPromptWidthWithoutInvokingReveal() throws {
        _ = NSApplication.shared
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        AppLanguage.current = "en"
        let summary = BrokerCredentialWriteSummary(credentialName: "Service", operation: .modify,
            before: [], after: [], beforeDigest: nil, afterDigest: nil,
            beforeUsageInstructions: "Original guidance", afterUsageInstructions: String(repeating: "Complete guidance\n", count: 200),
            beforeGroup: "Original", afterGroup: "New Group", createsGroup: true)
        var reveals = 0
        let view = FrozenWriteApprovalContent(writeSummary: summary, revealMaterial: {
            reveals += 1
            throw CancellationError()
        })
        let hosting = NSHostingView(rootView: view.frame(width: 252))
        let size = hosting.fittingSize
        XCTAssertEqual(size.width, 252)
        XCTAssertGreaterThan(size.height, 200)
        XCTAssertLessThan(size.height, 650, "Instructions scroll rather than growing the prompt without bound")
        XCTAssertEqual(reveals, 0, "Catalog-visible metadata requires no reveal authentication")
    }

    @MainActor
    func testLongGroupNamesDoNotPushApprovalActionsOutsideThePrompt() {
        _ = NSApplication.shared
        let request = BrokerApprovalOperationRequest(operationID: "synthetic", credentialID: "synthetic",
            targetID: "synthetic", operation: .modify, payloadDigest: String(repeating: "a", count: 64),
            credentialName: "Staging Service")
        func size(group: String) -> NSSize {
            let summary = BrokerCredentialWriteSummary(credentialName: "Staging Service", operation: .modify,
                before: [], after: [], beforeDigest: nil, afterDigest: nil,
                beforeUsageInstructions: "Original", afterUsageInstructions: String(repeating: "Guidance\n", count: 400),
                beforeGroup: group, afterGroup: group, createsGroup: true)
            return NSHostingView(rootView: FrozenAgentApprovalPrompt(request: request, timedAllowanceEnabled: true,
                writeSummary: summary, finish: { _ in })).fittingSize
        }
        let short = size(group: "Staging")
        let long = size(group: String(repeating: "Wide Group ", count: 23))
        XCTAssertEqual(long.width, FrozenAgentApprovalPrompt.width)
        XCTAssertEqual(long.height, short.height, accuracy: 1, "Complete group text must scroll within a bounded region")
        XCTAssertLessThan(long.height, 800)
    }
}
