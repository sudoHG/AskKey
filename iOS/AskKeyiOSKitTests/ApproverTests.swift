import AskKeyDevices
import SwiftUI
import XCTest
@testable import AskKeyiOSKit

/// The Mac's approval status, Mac names, removal, notifications and the
/// privacy cover (#314 acceptance 6, 7 and 8; #336 decisions 3 and 5).
@MainActor
final class ApproverTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
    }

    override func tearDown() async throws {
        world = nil
    }

    private var macID: String { world.macIdentity.deviceID.text }

    // MARK: Approval status

    func testPairingIsAllItTakesToApproveTheMacsRequests() async throws {
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, true)
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
    }

    func testAMacPairedBeforeTheRuleWithoutApprovalIsMarkedAndRefused() async throws {
        try await world.storeWithoutApprovalFlag()
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, false, "the row and the detail show the exception")
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
    }

    func testPairingAMacWithoutTheFlagAgainMakesThisIPhoneApproveIt() async throws {
        try await world.storeWithoutApprovalFlag()
        await world.model.removeMac(id: macID)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        _ = try await world.mac.poll()
        try await world.pair()
        XCTAssertEqual(world.model.pairedMacs.map(\.isApprover), [true])
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
    }

    // MARK: Removal

    func testRemovingTheMacStopsThisIPhoneAtOnceAndTellsTheMac() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        world.notifications.delivered = [PushHint(recordName: sealed.sealed.messageID.text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "request")]
        await world.model.becameActive()
        XCTAssertEqual(world.model.requests.count, 1)
        await world.model.removeMac(id: macID)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("request"))
        XCTAssertEqual(world.model.listNotice, .removed(name: TestWorld.macName, macWasTold: true))
        XCTAssertEqual(world.cloud.sent(.unpairNotice, from: phoneID).count, 1)
        // The Mac trusts this iPhone until it processes the unpair notice.
        _ = try await world.phoneEntry()
        _ = try await world.mac.poll()
        let entries = try await world.mac.pairedDevices()
        XCTAssertFalse(entries.contains { $0.deviceID == phoneID })
    }

    func testARemovalWhoseListWriteFailsStillStopsThisIPhone() async throws {
        let sealed = try await world.sendRequest()
        world.notifications.delivered = [PushHint(recordName: sealed.sealed.messageID.text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "request")]
        await world.model.becameActive()
        XCTAssertEqual(world.model.requests.count, 1)
        world.keychain.writesFail = true
        let removed = await world.model.removeMac(id: macID)
        XCTAssertFalse(removed)
        XCTAssertEqual(world.model.listNotice, .removalFailed)
        XCTAssertEqual(world.model.pairedMacs.map(\.isApprover), [false],
                       "the entry stays, so Remove can be tried again, and no longer shows as approving")
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("request"))
        world.keychain.writesFail = false
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "this process refuses the Mac's requests anyway")
        let retried = await world.model.removeMac(id: macID)
        XCTAssertTrue(retried)
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
    }

    func testRemovingAMacOrItsUnpairNoticeDropsItsCards() async throws {
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        await world.model.removeMac(id: macID)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)

        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.sendRequest(from: other)
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        try await other.messenger.removeDevice(try world.phone.deviceID)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "the removal hook runs before the unpair notice commits")
        XCTAssertEqual(world.model.listNotice, .removedByMac(name: "Office Mac"))
    }

    // MARK: Names

    func testMacsCanBeRenamedAndNamesStayUnique() async throws {
        let renamed = await world.model.renameMac(id: macID, to: "  Desk Mac  ")
        XCTAssertNil(renamed)
        XCTAssertEqual(world.model.pairedMacs.first?.name, "Desk Mac")
        let empty = await world.model.renameMac(id: macID, to: "   ")
        XCTAssertEqual(empty, .empty)

        let twin = world.makeMac(name: "Desk Mac")
        try await world.pair(twin)
        let twinRow = try XCTUnwrap(world.model.pairedMacs.first { $0.id == twin.deviceID.text })
        XCTAssertEqual(twinRow.name, "Desk Mac 2", "a newly paired Mac with a taken name gets a number")
        XCTAssertEqual(world.model.renamePrompt, RenamePrompt(macID: twin.deviceID.text, takenName: "Desk Mac",
                                                              newName: "Desk Mac 2"))
        let duplicate = await world.model.renameMac(id: twin.deviceID.text, to: "desk mac")
        XCTAssertEqual(duplicate, .duplicate("desk mac"))
        let laptop = await world.model.renameMac(id: twin.deviceID.text, to: "Laptop")
        XCTAssertNil(laptop)
        XCTAssertNil(world.model.renamePrompt)
        XCTAssertEqual(Set(world.model.pairedMacs.map(\.name)), ["Desk Mac", "Laptop"])
    }

    func testNumberedNamesFitTheDisplayNameLimit() {
        let long = String(repeating: "M", count: 64)
        let numbered = AppModel.numberedName(long, taken: [long])
        XCTAssertTrue(numbered.hasSuffix(" 2"))
        XCTAssertEqual(numbered.unicodeScalars.count, 64)
        XCTAssertEqual(AppModel.numberedName("Mac", taken: ["Mac", "mac 2"]), "Mac 3")
    }

    // MARK: Notifications

    func testTappingANotificationOpensItsRequest() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        let name = sealed.sealed.messageID.text
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: name),
                                       arrivedAt: world.clock.now(), notificationIdentifier: "tapped", opened: true)
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
    }

    func testANotificationThatIsOnlyShownOpensNothing() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: sealed.sealed.messageID.text),
                                       arrivedAt: world.clock.now(), notificationIdentifier: "front")
        XCTAssertNil(world.model.openedRequest)
    }

    func testOpeningANotificationThatLaunchesTheAppOpensItsRequest() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        let name = sealed.sealed.messageID.text
        let launched = AppModel(environment: world.environment)
        await launched.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: name), arrivedAt: world.clock.now(),
                                    notificationIdentifier: "opened", opened: true)
        await launched.start()
        await launched.becameActive()
        XCTAssertEqual(launched.openedRequest, OpenedRequest(id: name))
    }

    func testSettledRequestsLoseTheirNotifications() async throws {
        let sealed = try await world.sendRequest()
        world.notifications.delivered = [PushHint(recordName: sealed.sealed.messageID.text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "request")]
        await world.model.becameActive()
        XCTAssertEqual(world.model.requests.count, 1)
        XCTAssertFalse(world.notifications.removedIdentifiers.contains("request"), "still pending")
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("request"))
    }

    func testAnExpiredRequestLosesItsNotificationAtTheNextLaunch() async throws {
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        world.clock.advance(by: 300)
        world.notifications.delivered = [PushHint(recordName: sealed.sealed.messageID.text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "stale")]
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        await relaunched.becameActive()
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("stale"))
    }

    // MARK: Privacy cover

    func testThePrivacyCoverHidesTheAppExceptDuringAFaceIDPrompt() {
        XCTAssertTrue(PrivacyCover.isShown(phase: .background, authenticating: false))
        XCTAssertTrue(PrivacyCover.isShown(phase: .background, authenticating: true))
        XCTAssertTrue(PrivacyCover.isShown(phase: .inactive, authenticating: false), "app switcher snapshots")
        XCTAssertFalse(PrivacyCover.isShown(phase: .inactive, authenticating: true), "the Face ID prompt sees the card")
        XCTAssertFalse(PrivacyCover.isShown(phase: .active, authenticating: false))
    }
}
