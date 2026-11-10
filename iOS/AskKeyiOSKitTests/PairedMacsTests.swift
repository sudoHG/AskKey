import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

@MainActor
final class PairedMacsTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
    }

    override func tearDown() async throws {
        world = nil
    }

    private var macRowID: String { world.macIdentity.deviceID.text }

    func testRemovalTakesEffectAtOnceAndSendsAnUnpairNotice() async throws {
        let phoneID = try world.phone.deviceID
        await world.model.removeMac(id: macRowID)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        XCTAssertEqual(world.model.listNotice, .removed(name: TestWorld.macName, macWasTold: true))
        XCTAssertEqual(world.cloud.sent(.unpairNotice, from: phoneID).count, 1)
        _ = try await world.mac.poll()
        let macList = try await world.mac.pairedDevices()
        XCTAssertTrue(macList.isEmpty, "the Mac removes this iPhone when it processes the notice")
    }

    func testRemovalWhenTheNoticeCannotBeSentSaysSo() async throws {
        world.cloud.failSends { $0.kind == Int64(MessageKind.unpairNotice.rawValue) }
        await world.model.removeMac(id: macRowID)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        XCTAssertEqual(world.model.listNotice, .removed(name: TestWorld.macName, macWasTold: false))
    }

    func testDeliveryCheckIsAnsweredAtOnceWithoutAPromptAndRecordedAsPolling() async throws {
        let phone = try world.phone
        let prompts = phone.approvalReasons.count
        let check = try await world.mac.sendDeliveryCheck(to: phone.deviceID)
        world.clock.advance(by: 3)
        await world.model.becameActive()
        XCTAssertEqual(world.cloud.sent(.deliveryCheckReply, from: phone.deviceID).count, 1)
        XCTAssertEqual(phone.approvalReasons.count, prompts, "a delivery reply never asks for Face ID")
        XCTAssertEqual(world.model.pairedMacs.first?.lastReachedAt, world.clock.now())
        XCTAssertEqual(world.model.deliveryRecords,
                       [DeliveryRecord(recordName: check.text, arrivedAt: world.clock.now(), source: .polling)])
        XCTAssertEqual(world.localState.deliveryRecords, world.model.deliveryRecords)
        _ = try await world.mac.poll()
        let macList = try await world.mac.pairedDevices()
        XCTAssertEqual(macList.first?.isReached, true)
    }

    func testDeliveredNotificationIsRecordedWithItsArrivalTimeAndCleared() async throws {
        let phoneID = try world.phone.deviceID
        let check = try await world.mac.sendDeliveryCheck(to: phoneID)
        let arrival = world.clock.now().addingTimeInterval(1)
        world.notifications.delivered = [PushHint(recordName: check.text, arrivedAt: arrival, notificationIdentifier: "n1")]
        world.clock.advance(by: 30)
        await world.model.becameActive()
        XCTAssertEqual(world.model.deliveryRecords, [DeliveryRecord(recordName: check.text, arrivedAt: arrival, source: .push)])
        XCTAssertEqual(world.notifications.removedIdentifiers, ["n1"])
        XCTAssertEqual(world.cloud.sent(.deliveryCheckReply, from: phoneID).count, 1)
    }

    func testPushReceivedWhileRunningForAnotherDeviceIsIgnored() async throws {
        let phoneID = try world.phone.deviceID
        let check = try await world.mac.sendDeliveryCheck(to: phoneID)
        await world.model.receivedPush(userInfo: ["aps": ["alert": "Approve now"]], arrivedAt: world.clock.now(),
                                       notificationIdentifier: "foreign")
        XCTAssertTrue(world.cloud.sent(.deliveryCheckReply, from: phoneID).isEmpty,
                      "a notification that is not a hint for this inbox triggers nothing")
        await world.model.processInbox()
        XCTAssertEqual(world.model.deliveryRecords.map(\.recordName), [check.text])
        XCTAssertEqual(world.model.deliveryRecords.first?.source, .polling)
    }

    func testUnpairNoticeFromTheMacRemovesItAndSaysSo() async throws {
        let phoneID = try world.phone.deviceID
        try await world.mac.removeDevice(phoneID)
        await world.model.becameActive()
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        XCTAssertEqual(world.model.listNotice, .removedByMac(name: TestWorld.macName))
    }

    func testMessagesFromARemovedMacAreRefused() async throws {
        let phoneID = try world.phone.deviceID
        await world.model.removeMac(id: macRowID)
        world.model.listNotice = nil
        // The Mac has not processed the notice yet and still sends a check.
        _ = try? await world.mac.sendDeliveryCheck(to: phoneID)
        await world.model.processInbox()
        XCTAssertTrue(world.cloud.sent(.deliveryCheckReply, from: phoneID).isEmpty)
        XCTAssertTrue(world.model.deliveryRecords.isEmpty)
    }

    func testSignedOutAccountShowsMacsAsUnreachableAndKeepsTheList() async throws {
        world.cloud.accountState = .noAccount
        await world.model.refreshAccount()
        XCTAssertEqual(world.model.accountNotice, .signedOut)
        XCTAssertEqual(world.model.pairedMacs.count, 1)
        world.cloud.accountState = .available(userRecordName: "_user-a")
        await world.model.processInbox()
        XCTAssertNil(world.model.accountNotice)
    }

    func testAccountChangeDropsTheTokenAndPreparesTheInboxAgain() async throws {
        let phoneID = try world.phone.deviceID
        world.cloud.accountState = .available(userRecordName: "_user-b")
        await world.model.refreshAccount()
        XCTAssertEqual(world.localState.inboxPosition, InboxPosition(userRecordName: "_user-b", token: nil))
        XCTAssertEqual(world.cloud.preparedDevices.filter { $0 == phoneID }.count, 2)
        XCTAssertEqual(world.model.pairedMacs.count, 1, "the list is kept")
    }

    func testTokenIsStoredWithTheAccountAfterAPoll() async throws {
        _ = try await world.mac.sendDeliveryCheck(to: try world.phone.deviceID)
        await world.model.processInbox()
        XCTAssertEqual(world.localState.inboxPosition?.userRecordName, "_user-a")
        XCTAssertNotNil(world.localState.inboxPosition?.token)
    }
}
