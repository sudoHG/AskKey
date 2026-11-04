import UserNotifications
import XCTest
@testable import AskKeyAppKit

final class SoftwareUpdateReminderTests: XCTestCase {
    func testOnlyScheduledChecksWithGrantedPermissionPostAReminder() {
        XCTAssertTrue(SoftwareUpdateReminder.shouldPost(userInitiated: false, authorization: .authorized))
        XCTAssertTrue(SoftwareUpdateReminder.shouldPost(userInitiated: false, authorization: .provisional))
        for authorization in [UNAuthorizationStatus.notDetermined, .denied] {
            XCTAssertFalse(
                SoftwareUpdateReminder.shouldPost(userInitiated: false, authorization: authorization),
                "never asks for permission: \(authorization.rawValue)"
            )
        }
        for authorization in [UNAuthorizationStatus.notDetermined, .denied, .authorized, .provisional] {
            XCTAssertFalse(
                SoftwareUpdateReminder.shouldPost(userInitiated: true, authorization: authorization),
                "a user-initiated check shows its own alert: \(authorization.rawValue)"
            )
        }
    }

    func testReminderNamesTheVersionAndRoutesOnlyToTheUpdate() {
        let request = SoftwareUpdateReminder.request(version: "9.8.7")
        XCTAssertEqual(request.identifier, "com.sudohg.askkey.software-update")
        XCTAssertEqual(request.identifier, SoftwareUpdateReminder.identifier)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(request.content.userInfo as NSDictionary, ["route": "softwareUpdate"] as NSDictionary)
        XCTAssertEqual(NotificationRoute(userInfo: request.content.userInfo), .softwareUpdate)
        XCTAssertTrue(request.content.body.contains("9.8.7"))
        XCTAssertFalse(request.content.title.isEmpty)
        XCTAssertNil(request.content.badge, "the reminder never adds a badge")
    }

    func testReminderCopyIsTranslated() {
        XCTAssertEqual(AppLanguage.localized("Ask Key update available", language: "en"), "Ask Key update available")
        XCTAssertEqual(AppLanguage.localized("Ask Key update available", language: "zh-Hans"), "请旨有新版本") // i18n-literal: Chinese catalog assertion
        let body = "Version %@ is available. Click to review it."
        XCTAssertEqual(AppLanguage.localized(body, language: "en"), body)
        XCTAssertEqual(AppLanguage.localized(body, language: "zh-Hans"), "版本 %@ 已推出，点击查看。") // i18n-literal: Chinese catalog assertion
    }
}
