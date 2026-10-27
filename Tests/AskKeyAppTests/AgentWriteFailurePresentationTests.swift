import Foundation
import XCTest
import AskKeyBroker
import AskKeyVault
@testable import AskKeyAppKit

final class AgentWriteFailurePresentationTests: XCTestCase {
    func testApprovedFailureDoesNotActivateTheAppOrOrderWindowsForward() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let lifecycle = try String(contentsOf: root.appendingPathComponent(
            "Sources/AskKeyAppKit/App/AppDelegate+BrokerLifecycle.swift"), encoding: .utf8)
        let approval = try String(contentsOf: root.appendingPathComponent(
            "Sources/AskKeyAppKit/App/AppDelegate+Approval.swift"), encoding: .utf8)
        let failure = try body(after: "catch VaultError.agentWriteNameUnavailable", in: lifecycle)
            + body(after: "catch VaultError.agentWriteMaterialTooLarge", in: lifecycle)
        let presentation = try body(after: "private func presentAgentWriteFailure(", in: approval)
        let notification = try body(after: "private func postApprovalNotification(", in: approval)
        let path = failure + presentation + notification
        for forbidden in ["openManagementWindow", ".activate(", "makeKeyAndOrderFront", "orderFront",
                          "bringForward", "setActivationPolicy"] {
            XCTAssertFalse(path.contains(forbidden), "Approved failure must preserve the user's focus: \(forbidden)")
        }
        XCTAssertTrue(presentation.contains("vault.errorMessage = message"))
        XCTAssertTrue(presentation.contains("postApprovalNotification"))
        XCTAssertTrue(notification.contains("NSApp.dockTile.badgeLabel = \"!\""))
        XCTAssertTrue(notification.contains("completion(.authorizationUnavailable)"))
        XCTAssertTrue(notification.contains(".deliveryFailed"))
        XCTAssertFalse(notification.contains("requestAuthorization"))
    }

    func testFailureMessageIsLocalizedWithoutCredentialMetadata() {
        let key = "This credential name is already in use. The credential was not saved."
        XCTAssertEqual(AppLanguage.localized(key, language: "en"), key)
        XCTAssertEqual(AppLanguage.localized(key, language: "zh-Hans"),
            "\u{6B64}\u{51ED}\u{8BC1}\u{540D}\u{79F0}\u{5DF2}\u{88AB}\u{4F7F}\u{7528}\u{FF0C}\u{51ED}\u{8BC1}\u{672A}\u{4FDD}\u{5B58}\u{3002}")
    }

    func testSizeFailureMessageIsLocalizedWithoutCredentialMetadata() {
        let key = "The updated credential exceeds the 5 MiB size limit. The credential was not saved."
        XCTAssertEqual(AppLanguage.localized(key, language: "en"), key)
        XCTAssertEqual(AppLanguage.localized(key, language: "zh-Hans"), "更新后的凭证超过 5 MiB 大小限制，凭证未保存。") // i18n-literal: Assert the Simplified Chinese size rejection.
    }

    func testSizeRejectionNotifiesTheAppAndUsesExistingBrokerResourceError() throws {
        var notified = false
        XCTAssertThrowsError(try mapAgentTextWriteProviderError(onMaterialTooLarge: { notified = true }) { () -> Void in
            throw VaultError.agentWriteMaterialTooLarge
        }) { XCTAssertEqual($0 as? BrokerProviderError, .resourceExhausted) }
        XCTAssertTrue(notified)
        let handler = BrokerRequestHandler(catalog: { _ in [] }, requestStatus: { _, _ in nil },
            commitTextWrite: { _, _, _ in
                try mapAgentTextWriteProviderError { throw VaultError.agentWriteMaterialTooLarge }
            })
        let response = handler.handle(.init(version: BrokerProtocolVersion.current, method: "credential.write.commit",
            requestID: "synthetic-request", capability: "synthetic-capability",
            textWrite: .init(operationID: "synthetic-operation", action: .delete(name: "Synthetic"))))
        XCTAssertEqual(response, .failure(.resourceExhausted))
    }

    private func body(after marker: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: marker))
        let opening = try XCTUnwrap(source[start.upperBound...].firstIndex(of: "{"))
        var depth = 0
        for index in source[opening...].indices {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" { depth -= 1 }
            if depth == 0 { return String(source[opening...index]) }
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
