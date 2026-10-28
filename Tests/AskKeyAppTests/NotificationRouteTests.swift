import UserNotifications
import XCTest
import AskKeyVault
@testable import AskKeyAppKit

final class NotificationRouteTests: XCTestCase {
    private let id = "00000000-0000-0000-0000-000000000212"

    func testRoutesRoundTripWithOnlyAllowedMetadata() {
        let pending = NotificationRoute.pendingRequests.userInfo
        XCTAssertEqual(pending as NSDictionary, ["route": "pendingRequests"] as NSDictionary)
        XCTAssertEqual(NotificationRoute(userInfo: pending), .pendingRequests)
        let credential = NotificationRoute.credential(id).userInfo
        XCTAssertEqual(credential as NSDictionary,
                       ["route": "credential", "credentialID": id] as NSDictionary)
        XCTAssertEqual(NotificationRoute(userInfo: credential), .credential(id))
    }

    func testUnknownLegacyAndMalformedPayloadsFallBackToMain() {
        let payloads: [[AnyHashable: Any]] = [
            [:], ["route": "future"], ["route": 1],
            ["route": "credential"], ["route": "credential", "credentialID": 212],
            ["route": "credential", "credentialID": ""],
            ["route": "credential", "credentialID": "synthetic-name"],
            ["route": "credential", "credentialID": String(repeating: "a", count: 4096)],
            ["route": "pendingRequests", "credentialID": id],
            ["route": "credential", "credentialID": id, "name": "SYNTHETIC"],
        ]
        for payload in payloads {
            XCTAssertEqual(NotificationRoute(userInfo: payload), .main)
        }
    }

    func testExpirySenderTagsImmediateAndScheduledNotificationsWithoutCredentialContents() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for kind in [CredentialExpiryReminderScheduler.Delivery.Kind.immediate,
                     .scheduled(now.addingTimeInterval(3600))] {
            var request: UNNotificationRequest?
            UserNotificationExpiryReminderDelivery.post(
                .init(id: id, kind: kind), now: now,
                add: { request = $0; $1(nil) }, completion: { XCTAssertNil($0) }
            )
            XCTAssertEqual(request?.content.userInfo as? [String: String],
                           ["route": "credential", "credentialID": id])
            XCTAssertFalse(request?.content.body.contains(id) ?? true)
            XCTAssertFalse(request?.content.title.contains(id) ?? true)
        }
    }
}
