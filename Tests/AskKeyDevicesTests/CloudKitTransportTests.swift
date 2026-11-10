@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CloudKit
import XCTest

final class CloudKitTransportTests: XCTestCase {
    private let clock = ManualDeviceClock()
    private let service = FakeCloudKitService()
    private let log = CloudKitEventLog()
    private let mac = SoftwareDeviceIdentity().deviceID
    private let phone = SoftwareDeviceIdentity().deviceID

    private func transport(_ device: DeviceID, _ platform: DevicePlatform) -> CloudKitDeviceTransport {
        CloudKitDeviceTransport(service: service, deviceID: device, platform: platform, clock: clock, log: log.sink)
    }

    private func envelope(_ kind: MessageKind = .deliveryCheck, to recipient: DeviceID? = nil) -> DeviceEnvelope {
        DeviceEnvelope(recordType: kind.recordType, recordName: MessageID.random().text, sender: mac.text,
                       recipient: (recipient ?? phone).text, kind: Int64(kind.rawValue), sentAt: clock.now(),
                       expiresAt: clock.now().addingTimeInterval(600), body: Data([1, 2, 3]))
    }

    // MARK: Send

    func testSendWritesIntoTheRecipientsExistingInbox() async throws {
        _ = try await transport(phone, .iOS).prepareInbox()
        let sent = envelope()
        try await transport(mac, .macOS).send(sent)
        let records = service.records(inZone: "inbox_" + phone.text)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first.flatMap(CloudKitMessageRecord.envelope(from:)), sent)
        XCTAssertEqual(records.first?.recordType, "AlertMessage")
    }

    func testSendToADeviceWithoutAnInboxIsUnreachableAndCreatesNoZone() async throws {
        await XCTAssertThrowsErrorAsync(try await transport(mac, .macOS).send(envelope())) {
            XCTAssertEqual($0 as? DeviceTransportError, .recipientUnreachable)
        }
        XCTAssertEqual(service.zoneNames, [])
        XCTAssertEqual(service.savedZoneNames, [], "never another device's zone")
        var invalid = envelope()
        invalid.recipient = "nobody"
        await XCTAssertThrowsErrorAsync(try await transport(mac, .macOS).send(invalid)) {
            XCTAssertEqual($0 as? DeviceTransportError, .recipientUnreachable)
        }
    }

    func testAFailedSendIsNotRetried() async throws {
        _ = try await transport(phone, .iOS).prepareInbox()
        service.nextCreateErrors = [CKError(.networkFailure)]
        await XCTAssertThrowsErrorAsync(try await transport(mac, .macOS).send(envelope())) {
            XCTAssertEqual($0 as? DeviceTransportError, .networkUnavailable)
        }
        XCTAssertEqual(service.createdRecords.count, 1)
        XCTAssertEqual(service.records(inZone: "inbox_" + phone.text), [])
    }

    func testAResentMessageThatWasAlreadySavedCountsAsSent() async throws {
        _ = try await transport(phone, .iOS).prepareInbox()
        let sent = envelope(.pairingReveal)
        let sender = transport(mac, .macOS)
        try await sender.send(sent)
        try await sender.send(sent)
        XCTAssertEqual(service.records(inZone: "inbox_" + phone.text).count, 1)
    }

    // MARK: Fetch and delete

    func testFetchSortsRecordsIntoEnvelopesMalformedAndFailed() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        let good = envelope()
        let unreadable = envelope()
        try await transport(mac, .macOS).send(good)
        try await transport(mac, .macOS).send(unreadable)
        let malformed = CKRecord(recordType: "QuietMessage",
                                 recordID: CKRecord.ID(recordName: MessageID.random().text,
                                                       zoneID: CloudKitInboxLayout.zoneID(for: phone)))
        malformed["sender"] = mac.text as NSString
        service.insert(malformed)
        service.unreadableRecordNames = [unreadable.recordName]
        let changes = try await inbox.fetchInboxChanges(of: phone, since: nil)
        XCTAssertEqual(changes.envelopes, [good])
        XCTAssertEqual(changes.malformedRecordNames, [malformed.recordID.recordName])
        XCTAssertEqual(changes.failedRecordNames, [unreadable.recordName])
        XCTAssertFalse(changes.moreComing)
    }

    func testAnExpiredTokenIsReportedSoTheCallerFetchesFromNoToken() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        let first = try await inbox.fetchInboxChanges(of: phone, since: nil)
        service.expireTokens(ofZone: "inbox_" + phone.text)
        await XCTAssertThrowsErrorAsync(try await inbox.fetchInboxChanges(of: phone, since: first.newToken)) {
            XCTAssertEqual($0 as? DeviceTransportError, .changeTokenExpired)
        }
    }

    func testAMissingOwnZoneIsCreatedAgainWithItsSubscriptions() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        let token = try await inbox.fetchInboxChanges(of: phone, since: nil).newToken
        service.removeZone(named: "inbox_" + phone.text)
        service.removeSubscription("inbox_\(phone.text)_alert")
        service.removeSubscription("inbox_\(phone.text)_quiet")
        clock.advance(by: 5)
        let changes = try await inbox.fetchInboxChanges(of: phone, since: token)
        XCTAssertEqual(changes.envelopes, [])
        XCTAssertTrue(service.zoneNames.contains("inbox_" + phone.text))
        XCTAssertEqual(Array(log.events.suffix(3)), [
            .inboxZoneRecreated(at: clock.now()),
            .subscriptionSaved(subscriptionID: "inbox_\(phone.text)_alert", at: clock.now()),
            .subscriptionSaved(subscriptionID: "inbox_\(phone.text)_quiet", at: clock.now()),
        ])
        try await transport(mac, .macOS).send(envelope())
        let next = try await inbox.fetchInboxChanges(of: phone, since: changes.newToken)
        XCTAssertEqual(next.envelopes.count, 1, "the new zone's token works")
    }

    func testAMissingOwnZoneKeepsSubscriptionsThatStillMatch() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        service.removeZone(named: "inbox_" + phone.text)
        _ = try await inbox.fetchInboxChanges(of: phone, since: nil)
        XCTAssertEqual(service.savedSubscriptionIDs.count, 2, "only the first creation saved them")
        XCTAssertEqual(log.events.last, .inboxZoneRecreated(at: clock.now()))
    }

    func testDeletionTreatsGoneRecordsAsDeletedAndReportsOtherFailures() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        let kept = envelope()
        let deleted = envelope()
        try await transport(mac, .macOS).send(kept)
        try await transport(mac, .macOS).send(deleted)
        try await inbox.deleteMessages([deleted.recordName, MessageID.random().text], from: phone)
        XCTAssertEqual(service.records(inZone: "inbox_" + phone.text).map(\.recordID.recordName), [kept.recordName])

        service.recordDeleteErrors = [kept.recordName: CKError(.serviceUnavailable)]
        await XCTAssertThrowsErrorAsync(try await inbox.deleteMessages([kept.recordName], from: phone)) {
            XCTAssertEqual($0 as? DeviceTransportError, .serviceUnavailable)
        }
        service.removeZone(named: "inbox_" + phone.text)
        service.recordDeleteErrors = [:]
        try await inbox.deleteMessages([kept.recordName], from: phone)
    }

    func testDeletionSendsAtMost400RecordsPerRequest() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        try await inbox.deleteMessages((0..<401).map { _ in MessageID.random().text }, from: phone)
        XCTAssertEqual(service.deleteBatchSizes, [400, 1])
    }

    func testRemovingTheInboxDeletesTheZoneAndBothSubscriptions() async throws {
        let inbox = transport(phone, .iOS)
        _ = try await inbox.prepareInbox()
        try await inbox.removeInbox()
        XCTAssertEqual(service.zoneNames, [])
        XCTAssertNil(service.storedSubscription("inbox_\(phone.text)_alert"))
        XCTAssertNil(service.storedSubscription("inbox_\(phone.text)_quiet"))
        try await inbox.removeInbox()
    }

    // MARK: Errors

    func testCloudKitErrorsMapToTransportErrors() {
        let cases: [(Error, DeviceTransportError)] = [
            (CKError(.networkUnavailable), .networkUnavailable),
            (CKError(.networkFailure), .networkUnavailable),
            (CKError(.serverResponseLost), .networkUnavailable),
            (URLError(.notConnectedToInternet), .networkUnavailable),
            (CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 12.5]), .rateLimited(retryAfter: 12.5)),
            (CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 3.0]), .rateLimited(retryAfter: 3)),
            (CKError(.requestRateLimited), .rateLimited(retryAfter: nil)),
            (CKError(.quotaExceeded), .quotaExceeded),
            (CKError(.notAuthenticated), .notAuthenticated),
            (CKError(.accountTemporarilyUnavailable), .notAuthenticated),
            (CKError(.zoneNotFound), .recipientUnreachable),
            (CKError(.userDeletedZone), .recipientUnreachable),
            (CKError(.changeTokenExpired), .changeTokenExpired),
            (CKError(.serviceUnavailable), .serviceUnavailable),
            (CKError(.internalError), .serviceUnavailable),
            (CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: ["a": CKError(.quotaExceeded)]]), .quotaExceeded),
            (DeviceTransportError.notAuthenticated, .notAuthenticated),
            (CocoaError(.fileNoSuchFile), .serviceUnavailable),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(CloudKitErrorMapping.transportError(for: error) as? DeviceTransportError, expected, "\(error)")
        }
    }

    // MARK: Account

    func testAccountStates() async {
        let inbox = transport(phone, .iOS)
        service.userRecordNameValue = "_first"
        await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: nil), .available(userRecordName: "_first"))
        await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: "_first"), .available(userRecordName: "_first"))
        service.userRecordNameValue = "_second"
        await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: "_first"),
                                  .accountChanged(userRecordName: "_second"), "changed while the App was not running")
        let states: [(CKAccountStatus, CloudKitAccountState)] = [
            (.noAccount, .noAccount), (.restricted, .restricted), (.temporarilyUnavailable, .temporarilyUnavailable),
            (.couldNotDetermine, .temporarilyUnavailable),
        ]
        for (status, expected) in states {
            service.status = status
            await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: "_first"), expected, "\(status)")
        }
        service.statusError = CKError(.notAuthenticated)
        await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: nil), .noAccount)
        service.statusError = CKError(.networkUnavailable)
        await XCTAssertEqualAsync(await inbox.accountState(storedUserRecordName: nil), .temporarilyUnavailable)
    }

    func testAccountChangesFollowTheSystemNotification() async {
        let center = NotificationCenter()
        var changes = CloudKitDeviceTransport.accountChanges(notificationCenter: center).makeAsyncIterator()
        center.post(name: .CKAccountChanged, object: nil)
        center.post(name: .CKAccountChanged, object: nil)
        var count = 0
        for _ in 0..<2 {
            if await changes.next() != nil { count += 1 }
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: Containers

    func testTheModuleCreatesAContainerOnlyFromTheCallersIdentifier() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AskKeyDevices")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        var creations: [String] = []
        for file in files {
            let code = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
                .map { $0.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces) }
            XCTAssertFalse(code.contains { $0.contains("CKContainer.default") }, file.lastPathComponent)
            creations += code.filter { $0.contains("CKContainer(") }
        }
        XCTAssertEqual(creations, ["container = CKContainer(identifier: containerIdentifier)"])
    }
}
