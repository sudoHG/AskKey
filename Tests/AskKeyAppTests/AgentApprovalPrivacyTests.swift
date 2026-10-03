import Darwin
import Foundation
import XCTest
@testable import AskKeyAppKit
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyVault
@testable import AskKeyTestSupport

@MainActor
final class AgentApprovalPrivacyTests: AgentClientConnectorTestSupport {
    func testLockedApprovalUsesOnlyGenericReminderUntilScreenUnlocks() {
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .locked, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unlocked, language: "en"),
            .detailedConfirmation
        )
        XCTAssertEqual(
            AgentApprovalPrivacyPolicy.plan(screenState: .unknown, language: "en"),
            .lockedReminder(
                title: "Ask Key has pending requests",
                body: "Unlock your Mac to review a pending request."
            )
        )
    }

    func testApprovalDetailsAreLoadedOnlyAfterExplicitlyUnlockedScreenState() {
        var loads = 0
        let load = {
            loads += 1
            return 42
        }

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .locked, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("locked screen loaded request details")
        }
        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unknown, load: load) {
        case .lockedReminder: break
        case .detailed: XCTFail("unknown screen loaded request details")
        }
        XCTAssertEqual(loads, 0)

        switch AgentApprovalPrivacyPolicy.gatedRequest(screenState: .unlocked, load: load) {
        case .lockedReminder:
            XCTFail("unlocked screen did not load request")
        case .detailed(let request):
            XCTAssertEqual(request, 42)
        }
        XCTAssertEqual(loads, 1)
    }

    func testLockedReminderIsMarkedPostedOnlyAfterSuccessfulDelivery() {
        XCTAssertTrue(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .delivered)
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(
                for: .authorizationUnavailable
            )
        )
        XCTAssertFalse(
            LockedApprovalReminderDeliveryPolicy.marksNotificationPosted(for: .deliveryFailed)
        )
    }
}
