import AskKeyDevices
import CloudKit
import XCTest
@testable import AskKeyiOSKit

final class LocalizationTests: XCTestCase {
    private func table(_ language: String) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.kit.url(forResource: "Localizable", withExtension: "strings",
                                               subdirectory: nil, localization: language),
                                "the kit bundle has no \(language) strings")
        return try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
    }

    func testEveryStringHasEnglishAndSimplifiedChineseThatDiffer() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        for (key, value) in english {
            XCTAssertNotEqual(value, key, "\(key) has no English text")
            XCTAssertNotEqual(chinese[key], value, "\(key) is not translated")
        }
    }

    func testCodeSourceAndScanningInstructionsSayWhatTheyMust() throws {
        let english = try table("en")
        XCTAssertTrue(try XCTUnwrap(english["pairing.code.onlyHere"]).contains("never sends it in a notification or a message"))
        XCTAssertTrue(try XCTUnwrap(english["scanner.instruction"]).contains("on your own Mac"))
        XCTAssertTrue(try XCTUnwrap(english["scanner.instruction"]).contains("Never scan a pairing code that someone sends you"))
        XCTAssertTrue(try XCTUnwrap(english["pairing.failed.noChallenge"]).contains("don't enter any code"))
        // Before the wireless-data prompt is answered, the account check itself fails.
        XCTAssertTrue(try XCTUnwrap(english["welcome.failure.iCloudUnavailable"]).contains("Wireless Data"))
        XCTAssertTrue(try XCTUnwrap(english["welcome.failure.networkUnavailable"]).contains("Wireless Data"))
    }

    func testAlertKeysMatchTheSubscription() {
        XCTAssertEqual(CloudKitInboxLayout.alertTitleLocalizationKey, "push.message.title")
        XCTAssertEqual(CloudKitInboxLayout.alertBodyLocalizationKey, "push.message.body")
    }
}

final class PushHintReaderTests: XCTestCase {
    private let device = DeviceID(rawValue: Data(repeating: 7, count: 16))!
    private let other = DeviceID(rawValue: Data(repeating: 9, count: 16))!

    func testAQueryNotificationForThisInboxIsAHint() throws {
        let info = TestWorld.alertPush(for: device, record: "abc")
        let arrival = Date(timeIntervalSince1970: 1_800_000_000)
        let hint = PushHintReader.hint(userInfo: info, arrivedAt: arrival, notificationIdentifier: "n", for: device)
        XCTAssertEqual(hint, PushHint(recordName: "abc", arrivedAt: arrival, notificationIdentifier: "n"))
    }

    func testAnotherDevicesPushOrAPlainAlertIsNotAHint() {
        let zone = CloudKitInboxLayout.zoneName(for: other)
        let foreign = TestWorld.pushPayload(subscription: zone + "_alert", zone: zone, record: "abc")
        XCTAssertNil(PushHintReader.hint(userInfo: foreign, arrivedAt: Date(), notificationIdentifier: nil, for: device))
        let plain: [AnyHashable: Any] = ["aps": ["alert": "Enter 123 456 on your Mac"]]
        XCTAssertNil(PushHintReader.hint(userInfo: plain, arrivedAt: Date(), notificationIdentifier: nil, for: device))
    }
}
