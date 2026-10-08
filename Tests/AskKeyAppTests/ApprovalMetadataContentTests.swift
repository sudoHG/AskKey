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
        XCTAssertEqual(appLocalized("Unchanged"), "Unchanged")
        AppLanguage.current = "zh-Hans"
        XCTAssertEqual(appLocalized("Usage instructions"), "使用说明") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("Group"), "分组") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("New group — created when approved"), "新分组 · 批准后创建") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("None"), "无") // i18n-literal: Assert Simplified Chinese metadata approval copy.
        XCTAssertEqual(appLocalized("Unchanged"), "不变") // i18n-literal: Assert Simplified Chinese unchanged metadata copy.
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
        XCTAssertGreaterThan(long.height, short.height, "Short groups use their content height")
        XCTAssertLessThanOrEqual(long.height - short.height, 30, "Long groups stay within the existing height cap")
        XCTAssertLessThan(long.height, 680)
    }

    @MainActor
    func testCreateApprovalKeepsActionsWithinCIVisibleScreenHeight() {
        _ = NSApplication.shared
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let request = BrokerApprovalOperationRequest(operationID: "synthetic", credentialID: "synthetic",
            targetID: "synthetic", operation: .create, payloadDigest: String(repeating: "a", count: 64),
            credentialName: "Staging API", callerName: "E2E Agent")
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            for instructions in ["Use only for staging API requests. Consume STAGING_TOKEN; keep values out of logs.",
                                 String(repeating: "Guidance\n", count: 400)] {
                let summary = BrokerCredentialWriteSummary(credentialName: "Staging API", operation: .create,
                    before: [], after: [.init(name: "token", payloadKind: .text, byteCount: 24,
                        delivery: .environmentVariable("STAGING_TOKEN"), masked: true)],
                    beforeDigest: nil, afterDigest: nil, beforeUsageInstructions: nil,
                    afterUsageInstructions: instructions, beforeGroup: nil, afterGroup: "Staging Services", createsGroup: true)
                let size = NSHostingView(rootView: FrozenAgentApprovalPrompt(request: request, timedAllowanceEnabled: true,
                    writeSummary: summary, finish: { _ in })).fittingSize
                XCTAssertEqual(size.width, FrozenAgentApprovalPrompt.width)
                XCTAssertLessThan(size.height, 680, "Approval and Deny must fit the 768-point CI screen with menu bar and Dock")
            }
        }
    }

    @MainActor
    func testInstructionsHeightFollowsContentUntilTheCapInBothLanguages() {
        _ = NSApplication.shared
        withLanguages { language in
            let line = language == "en" ? "Short guidance" : "简短说明" // i18n-literal: Synthetic localized short instructions.
            let lineHeight = NSHostingView(rootView: Text(verbatim: line).font(Theme.Fonts.caption)
                .frame(width: 252)).fittingSize.height
            for operation in [BrokerApprovalOperation.create, .delete] {
                @MainActor
                func height(lines: Int) -> CGFloat {
                    let instructions = Array(repeating: line, count: lines).joined(separator: "\n")
                    return hosting(operation: operation, instructions: instructions).fittingSize.height
                }
                let short = height(lines: 1)
                let medium = height(lines: 2)
                let long = height(lines: 12)
                XCTAssertEqual(medium - short, lineHeight, accuracy: 1)
                XCTAssertEqual(long - short, 60 - lineHeight, accuracy: 1)
                XCTAssertEqual(height(lines: 40), long, accuracy: 1, "Overflow scrolls instead of growing the card")
            }
        }
    }

    @MainActor
    func testGroupHeightFollowsContentUntilTheCapInBothLanguages() {
        _ = NSApplication.shared
        withLanguages { language in
            let shortGroup = language == "en" ? "Staging" : "测试" // i18n-literal: Synthetic localized group names.
            let lineHeight = NSHostingView(rootView: Text(verbatim: shortGroup).font(Theme.Fonts.caption)
                .frame(width: 252)).fittingSize.height
            for operation in [BrokerApprovalOperation.create, .delete] {
                let short = hosting(operation: operation, group: shortGroup).fittingSize.height
                let long = hosting(operation: operation, group: String(repeating: shortGroup + " ", count: 25)).fittingSize.height
                XCTAssertEqual(long - short, 30 - lineHeight, accuracy: 1)
                let longer = hosting(operation: operation, group: String(repeating: shortGroup + " ", count: 30)).fittingSize.height
                XCTAssertEqual(longer, long, accuracy: 1, "Overflow groups scroll within the existing cap")
            }
        }
    }

    @MainActor
    func testDeleteOmitsFrozenContentWhileCreateAndModifyKeepItInBothLanguages() {
        _ = NSApplication.shared
        withLanguages { _ in
            // A missing summary renders the existing frozen-content block alone.
            let frozenHeight = NSHostingView(rootView: FrozenWriteApprovalContent(writeSummary: nil)
                .frame(width: 252)).fittingSize.height
            XCTAssertGreaterThan(frozenHeight, 80, "Measure the complete localized heading, reveal button and note")
            let deleteHeight = hosting(operation: .delete).fittingSize.height
            for operation in [BrokerApprovalOperation.create, .modify] {
                let writeHeight = hosting(operation: operation).fittingSize.height
                XCTAssertEqual(writeHeight - deleteHeight, frozenHeight + Theme.Spacing.sm, accuracy: 1,
                    "Delete omits the entire frozen block; create and modify retain it")
            }
        }
    }

    @MainActor
    private func withLanguages(_ assertion: @MainActor (String) -> Void) {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        for language in ["en", "zh-Hans"] {
            AppLanguage.current = language
            assertion(language)
        }
    }

    @MainActor
    private func hosting(operation: BrokerApprovalOperation, instructions: String = "Use only on staging.",
        group: String = "Staging") -> NSHostingView<some View> {
        let summary = BrokerCredentialWriteSummary(credentialName: "Staging API", operation: operation,
            before: [], after: [], beforeDigest: nil, afterDigest: nil,
            beforeUsageInstructions: instructions, afterUsageInstructions: instructions,
            beforeGroup: group, afterGroup: group)
        return NSHostingView(rootView: FrozenWriteApprovalContent(writeSummary: summary).frame(width: 252))
    }
}
