@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CloudKit
import XCTest

final class CloudKitSubscriptionTests: XCTestCase {
    private let device = SoftwareDeviceIdentity().deviceID
    private let clock = ManualDeviceClock()
    private let service = FakeCloudKitService()
    private let log = CloudKitEventLog()

    private var alertID: String { "inbox_\(device.text)_alert" }
    private var quietID: String { "inbox_\(device.text)_quiet" }

    /// A new transport is a new launch of the App.
    private func launch(_ platform: DevicePlatform = .iOS) -> CloudKitDeviceTransport {
        CloudKitDeviceTransport(service: service, deviceID: device, platform: platform, clock: clock, log: log.sink)
    }

    // MARK: Names and definitions

    func testZoneAndSubscriptionNamesComeFromTheDeviceID() {
        XCTAssertEqual(device.text.count, 26)
        XCTAssertEqual(CloudKitInboxLayout.zoneName(for: device), "inbox_" + device.text)
        let zoneID = CloudKitInboxLayout.zoneID(for: device)
        XCTAssertEqual(zoneID.zoneName, "inbox_" + device.text)
        XCTAssertEqual(zoneID.ownerName, CKCurrentUserDefaultName)
        XCTAssertEqual(CloudKitInboxLayout.subscriptionID(for: device, recordType: .alert), "inbox_" + device.text + "_alert")
        XCTAssertEqual(CloudKitInboxLayout.subscriptionID(for: device, recordType: .quiet), "inbox_" + device.text + "_quiet")
    }

    func testIPhoneSubscriptionsMatchTheADR() throws {
        let subscriptions = CloudKitInboxLayout.subscriptions(for: device, platform: .iOS)
        XCTAssertEqual(subscriptions.map(\.subscriptionID), [alertID, quietID])
        for subscription in subscriptions {
            try assertQuerySubscriptionBasics(subscription)
        }
        let alert = try XCTUnwrap(subscriptions.first { $0.recordType == "AlertMessage" }?.notificationInfo)
        XCTAssertEqual(alert.titleLocalizationKey, "push.message.title")
        XCTAssertEqual(alert.alertLocalizationKey, "push.message.body")
        XCTAssertEqual(alert.soundName, "default")
        XCTAssertTrue(alert.shouldSendMutableContent)
        XCTAssertEqual(alert.category, "askkey.message")
        XCTAssertEqual(alert.desiredKeys, ["kind", "recipient", "sender"])
        XCTAssertFalse(alert.shouldSendContentAvailable)
        XCTAssertFalse(alert.shouldBadge)
        XCTAssertNil(alert.alertBody)
        XCTAssertNil(alert.title)
        XCTAssertNil(alert.subtitle)
        XCTAssertNil(alert.subtitleLocalizationKey)
        XCTAssertNil(alert.alertLocalizationArgs)
        XCTAssertNil(alert.titleLocalizationArgs)
        XCTAssertNil(alert.subtitleLocalizationArgs)
        XCTAssertNil(alert.alertActionLocalizationKey)
        XCTAssertNil(alert.alertLaunchImage)
        XCTAssertNil(alert.collapseIDKey)
        let quiet = try XCTUnwrap(subscriptions.first { $0.recordType == "QuietMessage" }?.notificationInfo)
        try assertContentAvailableOnly(quiet)
    }

    func testMacSubscriptionsAreContentAvailableOnly() throws {
        let subscriptions = CloudKitInboxLayout.subscriptions(for: device, platform: .macOS)
        XCTAssertEqual(subscriptions.map(\.subscriptionID), [alertID, quietID])
        XCTAssertEqual(subscriptions.map(\.recordType), ["AlertMessage", "QuietMessage"])
        for subscription in subscriptions {
            try assertQuerySubscriptionBasics(subscription)
            try assertContentAvailableOnly(try XCTUnwrap(subscription.notificationInfo))
        }
    }

    func testPushesForOtherDevicesAreIgnored() {
        let other = SoftwareDeviceIdentity().deviceID
        let zone = "inbox_" + device.text
        XCTAssertTrue(CloudKitInboxLayout.isPush(subscriptionID: alertID, zoneName: zone, for: device))
        XCTAssertTrue(CloudKitInboxLayout.isPush(subscriptionID: quietID, zoneName: zone, for: device))
        XCTAssertFalse(CloudKitInboxLayout.isPush(subscriptionID: "inbox_\(other.text)_alert", zoneName: "inbox_" + other.text,
                                                  for: device), "another device's inbox")
        XCTAssertFalse(CloudKitInboxLayout.isPush(subscriptionID: "inbox_\(other.text)_quiet", zoneName: zone, for: device))
        XCTAssertFalse(CloudKitInboxLayout.isPush(subscriptionID: "someone-else", zoneName: zone, for: device),
                       "a subscription someone else created on this zone")
        XCTAssertFalse(CloudKitInboxLayout.isPush(subscriptionID: alertID, zoneName: nil, for: device))
        XCTAssertFalse(CloudKitInboxLayout.isPush(subscriptionID: nil, zoneName: zone, for: device))
    }

    // MARK: Create-once

    func testCreateOnceSavesOnlySubscriptionsReportedMissing() async throws {
        service.putSubscription(CloudKitInboxLayout.subscription(for: device, platform: .iOS, recordType: .quiet))
        let report = try await launch().prepareInbox()
        XCTAssertEqual(report, InboxPreparation(saved: [alertID]))
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID])
        XCTAssertEqual(log.events, [.subscriptionSaved(subscriptionID: alertID, at: clock.now())])
        XCTAssertTrue(service.zoneNames.contains("inbox_" + device.text), "the zone is created")
    }

    func testMatchingSubscriptionsAreNeverSavedAgain() async throws {
        let first = launch()
        _ = try await first.prepareInbox()
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID, quietID])
        let fetches = service.subscriptionFetchCount
        _ = try await first.prepareInbox()
        XCTAssertEqual(service.subscriptionFetchCount, fetches, "a completed preparation is not repeated in the process")
        for _ in 1...3 {
            clock.advance(by: 3600)
            let report = try await launch().prepareInbox()
            XCTAssertEqual(report, InboxPreparation())
        }
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID, quietID], "launches fetch, never save, a matching subscription")
        XCTAssertEqual(service.savedZoneNames.count, 4, "saving the existing zone is idempotent")
        XCTAssertEqual(log.events.count, 2)
    }

    func testReplacedDefinitionIsRepairedOnce() async throws {
        let replacements: [(String, () -> CKSubscription)] = [
            ("alert text without mutable content", {
                let subscription = CloudKitInboxLayout.subscription(for: self.device, platform: .iOS, recordType: .alert)
                let info = CKSubscription.NotificationInfo()
                info.alertBody = "Approve the request now"
                info.desiredKeys = CloudKitInboxLayout.desiredKeys
                subscription.notificationInfo = info
                return subscription
            }),
            ("another predicate", {
                let subscription = CKQuerySubscription(recordType: "AlertMessage", predicate: NSPredicate(format: "kind == 7"),
                                                       subscriptionID: self.alertID, options: [.firesOnRecordCreation])
                subscription.zoneID = CloudKitInboxLayout.zoneID(for: self.device)
                subscription.notificationInfo = CloudKitInboxLayout.notificationInfo(platform: .iOS, recordType: .alert)
                return subscription
            }),
            ("more options", {
                let expected = CloudKitInboxLayout.subscription(for: self.device, platform: .iOS, recordType: .alert)
                let subscription = CKQuerySubscription(recordType: "AlertMessage", predicate: NSPredicate(value: true),
                                                       subscriptionID: self.alertID,
                                                       options: [.firesOnRecordCreation, .firesOnRecordDeletion])
                subscription.zoneID = expected.zoneID
                subscription.notificationInfo = expected.notificationInfo
                return subscription
            }),
            ("another zone", {
                let subscription = CloudKitInboxLayout.subscription(for: self.device, platform: .iOS, recordType: .alert)
                subscription.zoneID = CKRecordZone.ID(zoneName: "inbox_other", ownerName: CKCurrentUserDefaultName)
                return subscription
            }),
            ("a database subscription", {
                let subscription = CKDatabaseSubscription(subscriptionID: self.alertID)
                subscription.notificationInfo = CloudKitInboxLayout.notificationInfo(platform: .iOS, recordType: .alert)
                return subscription
            }),
            ("a desired key dropped", {
                let subscription = CloudKitInboxLayout.subscription(for: self.device, platform: .iOS, recordType: .alert)
                subscription.notificationInfo?.desiredKeys = ["kind", "sender"]
                return subscription
            }),
        ]
        for (name, replacement) in replacements {
            let service = FakeCloudKitService()
            let log = CloudKitEventLog()
            service.putSubscription(CloudKitInboxLayout.subscription(for: device, platform: .iOS, recordType: .quiet))
            service.putSubscription(replacement())
            let transport = CloudKitDeviceTransport(service: service, deviceID: device, platform: .iOS, clock: clock,
                                                    log: log.sink)
            let report = try await transport.prepareInbox()
            XCTAssertEqual(report, InboxPreparation(saved: [alertID]), name)
            XCTAssertEqual(log.events, [.subscriptionRepaired(subscriptionID: alertID, at: clock.now())], name)
            let stored = try XCTUnwrap(service.storedSubscription(alertID), name)
            XCTAssertTrue(CloudKitSubscriptionDefinition.matches(
                stored, CloudKitInboxLayout.subscription(for: device, platform: .iOS, recordType: .alert)), name)
            let relaunched = CloudKitDeviceTransport(service: service, deviceID: device, platform: .iOS, clock: clock,
                                                     log: log.sink)
            _ = try await relaunched.prepareInbox()
            XCTAssertEqual(service.savedSubscriptionIDs, [alertID], "\(name): repaired once, then left alone")
        }
    }

    func testANetworkErrorSavesNothingAndALaterPreparationTriesAgain() async throws {
        let transport = launch()
        service.subscriptionFetchError = CKError(.networkUnavailable)
        await XCTAssertThrowsErrorAsync(try await transport.prepareInbox()) {
            XCTAssertEqual($0 as? DeviceTransportError, .networkUnavailable)
        }
        XCTAssertEqual(service.savedSubscriptionIDs, [])
        service.subscriptionFetchError = nil
        let report = try await transport.prepareInbox()
        XCTAssertEqual(report.saved, [alertID, quietID])
    }

    func testOnlyADoesNotExistAnswerLeadsToASave() async throws {
        service.subscriptionAnswers = [alertID: CKError(.networkFailure), quietID: CKError(.serverRejectedRequest)]
        let transport = launch()
        let report = try await transport.prepareInbox()
        XCTAssertEqual(report, InboxPreparation(pending: [alertID, quietID]))
        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(service.savedSubscriptionIDs, [])

        service.subscriptionAnswers = [:]
        _ = try await transport.fetchInboxChanges(of: device, since: nil)
        XCTAssertEqual(service.savedSubscriptionIDs, [], "a fetch within a minute does not prepare again")
        clock.advance(by: CloudKitDeviceTransport.preparationRetryInterval)
        _ = try await transport.fetchInboxChanges(of: device, since: nil)
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID, quietID], "a later fetch finishes the preparation")
        let fetches = service.subscriptionFetchCount
        clock.advance(by: 3600)
        _ = try await transport.fetchInboxChanges(of: device, since: nil)
        XCTAssertEqual(service.subscriptionFetchCount, fetches, "nothing is left to prepare")
    }

    func testAFailedSaveStaysPendingWithoutBeingLogged() async throws {
        service.subscriptionSaveErrors = [alertID: CKError(.networkFailure)]
        let report = try await launch().prepareInbox()
        XCTAssertEqual(report, InboxPreparation(saved: [quietID], pending: [alertID]))
        XCTAssertEqual(log.events, [.subscriptionSaved(subscriptionID: quietID, at: clock.now())])
    }

    func testARateLimitPushesTheNextAutomaticPreparationBack() async throws {
        let transport = launch()
        service.subscriptionFetchError = CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 300.0])
        await XCTAssertThrowsErrorAsync(try await transport.prepareInbox()) {
            XCTAssertEqual($0 as? DeviceTransportError, .rateLimited(retryAfter: 300))
        }
        service.subscriptionFetchError = nil
        clock.advance(by: 120)
        _ = try await transport.fetchInboxChanges(of: device, since: nil)
        XCTAssertEqual(service.savedSubscriptionIDs, [], "CloudKit asked to wait five minutes")
        clock.advance(by: 180)
        _ = try await transport.fetchInboxChanges(of: device, since: nil)
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID, quietID])
    }

    func testConcurrentPreparationsSaveEachSubscriptionOnce() async throws {
        let transport = launch()
        async let first = transport.prepareInbox()
        async let second = transport.prepareInbox()
        _ = try await (first, second)
        XCTAssertEqual(service.savedSubscriptionIDs, [alertID, quietID])
    }

    // MARK: Helpers

    private func assertQuerySubscriptionBasics(_ subscription: CKQuerySubscription, file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        XCTAssertEqual(subscription.subscriptionType, .query, file: file, line: line)
        XCTAssertEqual(subscription.predicate.predicateFormat, "TRUEPREDICATE", file: file, line: line)
        XCTAssertEqual(subscription.querySubscriptionOptions, [.firesOnRecordCreation], file: file, line: line)
        XCTAssertEqual(subscription.querySubscriptionOptions.rawValue, CKQuerySubscription.Options.firesOnRecordCreation.rawValue,
                       "the single option", file: file, line: line)
        XCTAssertEqual(subscription.zoneID?.zoneName, "inbox_" + device.text, file: file, line: line)
        XCTAssertEqual(subscription.zoneID?.ownerName, CKCurrentUserDefaultName, file: file, line: line)
        let suffix = subscription.recordType == "AlertMessage" ? "_alert" : "_quiet"
        XCTAssertEqual(subscription.subscriptionID, "inbox_" + device.text + suffix, file: file, line: line)
    }

    private func assertContentAvailableOnly(_ info: CKSubscription.NotificationInfo, file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        XCTAssertTrue(info.shouldSendContentAvailable, file: file, line: line)
        XCTAssertEqual(info.desiredKeys, ["kind", "recipient", "sender"], file: file, line: line)
        XCTAssertFalse(info.shouldSendMutableContent, file: file, line: line)
        XCTAssertFalse(info.shouldBadge, file: file, line: line)
        let texts: [String?] = [info.alertBody, info.alertLocalizationKey, info.title, info.titleLocalizationKey,
                                info.subtitle, info.subtitleLocalizationKey, info.alertActionLocalizationKey,
                                info.alertLaunchImage, info.soundName, info.category, info.collapseIDKey]
        XCTAssertEqual(texts.compactMap { $0 }, [], "no alert, sound or category", file: file, line: line)
        XCTAssertNil(info.alertLocalizationArgs, file: file, line: line)
        XCTAssertNil(info.titleLocalizationArgs, file: file, line: line)
        XCTAssertNil(info.subtitleLocalizationArgs, file: file, line: line)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: @autoclosure () -> String = "",
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("did not throw \(message())", file: file, line: line)
    } catch {
        handler(error)
    }
}
