@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CloudKit
import XCTest

/// `DeviceMessenger` over the CloudKit transport, with a stand-in for the
/// CloudKit calls: each device has its own transport on one shared account.
final class CloudKitPollingTests: XCTestCase {
    private let service = FakeCloudKitService()
    private let log = CloudKitEventLog()
    private let harness = DeviceHarness()

    override func setUp() {
        super.setUp()
        harness.makeTransport = { [service, log, clock = harness.clock] device, platform in
            CloudKitDeviceTransport(service: service, deviceID: device, platform: platform, clock: clock, log: log.sink)
        }
    }

    /// A device whose inbox and subscriptions exist.
    private func makeDevice(_ platform: DevicePlatform) async throws -> SimulatedDevice {
        let device = harness.makeDevice(platform)
        let transport = CloudKitDeviceTransport(service: service, deviceID: device.id, platform: platform,
                                                clock: harness.clock, log: log.sink)
        let report = try await transport.prepareInbox()
        XCTAssertTrue(report.isComplete)
        return device
    }

    private func inbox(_ device: SimulatedDevice) -> [String] {
        service.records(inZone: "inbox_" + device.id.text).map(\.recordID.recordName)
    }

    func testPairingAndADeliveryCheckLeaveEveryInboxEmpty() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        guard case .paired = await mac.phase(), case .paired = await phone.phase() else { return XCTFail("paired") }
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        XCTAssertEqual(service.records(inZone: "inbox_" + phone.id.text).first?.recordType, "AlertMessage")
        let delivered = try await phone.poll()
        XCTAssertEqual(delivered.processed, 1)
        let replied = try await mac.poll()
        XCTAssertEqual(replied.processed, 1)
        XCTAssertEqual(inbox(mac), [])
        XCTAssertEqual(inbox(phone), [])
        XCTAssertEqual(service.savedSubscriptionIDs.count, 4, "two per device, saved once")
    }

    func testAnExpiredTokenLeadsToAFullFetch() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let settled = try await XCTUnwrapAsync(await phone.messenger.inboxToken)
        service.expireTokens(ofZone: "inbox_" + phone.id.text)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let report = try await phone.poll()
        XCTAssertEqual(report.processed, 1, "the full fetch from no token found the check")
        await XCTAssertNotEqualAsync(try await XCTUnwrapAsync(await phone.messenger.inboxToken), settled)
        XCTAssertEqual(inbox(phone), [])
        await XCTAssertNotNilAsync(try await phone.entry(for: mac), "the list is kept")
    }

    func testAPartialFetchFailureKeepsTheTokenBehindTheUnfetchedMessage() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let token = await phone.messenger.inboxToken
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let unfetched = try XCTUnwrap(inbox(phone).first)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        service.unreadableRecordNames = [unfetched]
        let partial = try await phone.poll()
        XCTAssertEqual(partial.processed, 1)
        XCTAssertEqual(partial.outcomes[unfetched], .failed)
        XCTAssertEqual(inbox(phone), [unfetched], "not deleted")
        await XCTAssertEqualAsync(await phone.messenger.inboxToken, token, "the token stays behind the unfetched record")
        service.unreadableRecordNames = []
        let retried = try await phone.poll()
        XCTAssertEqual(retried.outcomes, [unfetched: .processed], "fetched again at the next poll")
        XCTAssertEqual(inbox(phone), [])
        await XCTAssertNotEqualAsync(await phone.messenger.inboxToken, token)
    }

    func testAMessageKeptForAnOpenSessionIsNeitherDeletedNorCountedAndIsDroppedWhenTheSessionEnds() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        // A writer to the account deletes the phone's reveal.
        let reveal = try XCTUnwrap(inbox(mac).first)
        service.removeRecord(named: reveal, fromZone: "inbox_" + mac.id.text)
        try await phone.confirm()
        let confirmation = try XCTUnwrap(inbox(mac).first)
        let token = await mac.messenger.inboxToken
        for poll in 1...5 {
            let report = try await mac.poll()
            XCTAssertEqual(report.outcomes, [confirmation: .keptForSession], "poll \(poll)")
            XCTAssertEqual(report.failed, 0, "poll \(poll)")
            XCTAssertEqual(inbox(mac), [confirmation], "poll \(poll)")
            await XCTAssertEqualAsync(await mac.messenger.inboxToken, token)
        }
        await mac.messenger.cancelPairing()
        let ended = try await mac.poll()
        XCTAssertEqual(ended.outcomes, [confirmation: .refused(.noSession)])
        XCTAssertEqual(inbox(mac), [], "dropped once the session ended")
        await XCTAssertNotEqualAsync(await mac.messenger.inboxToken, token)
    }

    func testAMessageThatFailsIsDeletedAtTheThirdFailure() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let token = await phone.messenger.inboxToken
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let check = try XCTUnwrap(inbox(phone).first)
        phone.store.failNextSaves(3)
        for attempt in 1...2 {
            let report = try await phone.poll()
            XCTAssertEqual(report.outcomes, [check: .failed], "attempt \(attempt)")
            XCTAssertEqual(inbox(phone), [check], "attempt \(attempt)")
            await XCTAssertEqualAsync(await phone.messenger.inboxToken, token)
        }
        let third = try await phone.poll()
        XCTAssertEqual(third.outcomes, [check: .refused(.repeatedFailure)])
        XCTAssertEqual(inbox(phone), [])
        await XCTAssertNotEqualAsync(await phone.messenger.inboxToken, token)
    }

    func testExpiredAndMalformedMessagesInTheOwnInboxAreDeletedDuringAFetch() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let expired = try XCTUnwrap(inbox(phone).first)
        let malformed = CKRecord(recordType: "AlertMessage",
                                 recordID: CKRecord.ID(recordName: MessageID.random().text,
                                                       zoneID: CloudKitInboxLayout.zoneID(for: phone.id)))
        malformed["body"] = Data([1]) as NSData
        service.insert(malformed)
        harness.clock.advance(by: MessageKind.deliveryCheckLifetime + 1)
        let report = try await phone.poll()
        XCTAssertEqual(report.outcomes, [expired: .refused(.expired), malformed.recordID.recordName: .refused(.malformed)])
        XCTAssertEqual(inbox(phone), [])
    }

    func testPagesAreFetchedUntilNoMoreAreComing() async throws {
        let mac = try await makeDevice(.macOS)
        let phone = try await makeDevice(.iOS)
        try await harness.pair(mac, phone)
        for _ in 1...3 { try await mac.messenger.sendDeliveryCheck(to: phone.id) }
        service.pageSize = 1
        let report = try await phone.poll()
        XCTAssertEqual(report.processed, 3)
        XCTAssertEqual(inbox(phone), [])
    }
}
