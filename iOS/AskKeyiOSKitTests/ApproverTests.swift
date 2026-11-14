import AskKeyDevices
import SwiftUI
import XCTest
@testable import AskKeyiOSKit

/// The approver confirmation, Mac names, removal, notifications and the
/// privacy cover (#314 acceptance 6, 7 and 8).
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

    // MARK: Approver confirmation

    func testApproveRequestsTakesTheCodeAsksForFaceIDSendsTheConfirmationAndSetsTheFlag() async throws {
        let phone = try world.phone
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, false, "off after pairing")
        world.model.startApproverConfirmation(macID: macID)
        XCTAssertEqual(world.model.approverConfirmation?.macName, TestWorld.macName)
        let authenticating = Box(false)
        phone.duringApprovalPrompt = { [model = world.model] in authenticating.value = await model.isAuthenticating }
        await world.model.confirmApprover(typed: " 042 917\n")
        XCTAssertTrue(authenticating.value)
        XCTAssertEqual(phone.approvalReasons.last?.contains("“\(TestWorld.macName)”"), true)
        XCTAssertEqual(world.model.approverConfirmation?.stage, .sent)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, true)

        _ = try await world.mac.poll()
        let confirmation = try XCTUnwrap(world.macInbox.messages.compactMap { message -> ApproverConfirmation? in
            if case .confirmation(let confirmation) = message.message { return confirmation }
            return nil
        }.first)
        let entry = try await world.phoneEntry()
        let code = try XCTUnwrap(ApproverCode(typed: "042917"))
        XCTAssertTrue(code.matches(proof: confirmation.codeProof, mac: world.macIdentity.deviceID, phone: phone.deviceID,
                                   pairingID: entry.pairingID), "the Mac's check of the code proof passes")
    }

    func testAnythingButSixDigitsSendsNothing() async throws {
        let phone = try world.phone
        let prompts = phone.approvalReasons.count
        world.model.startApproverConfirmation(macID: macID)
        for typed in ["12345", "1234567", "12345a", "１２３４５６"] {
            await world.model.confirmApprover(typed: typed)
            XCTAssertEqual(world.model.approverConfirmation?.problem, .invalidCode, typed)
            XCTAssertEqual(world.model.approverConfirmation?.stage, .entering)
        }
        XCTAssertEqual(phone.approvalReasons.count, prompts)
        XCTAssertTrue(world.cloud.sent(.approverConfirmation, from: phone.deviceID).isEmpty)
    }

    func testACancelledPromptSendsNothing() async throws {
        let phone = try world.phone
        phone.approvalBehavior = .cancel
        world.model.startApproverConfirmation(macID: macID)
        await world.model.confirmApprover(typed: TestWorld.approverCode)
        XCTAssertEqual(world.model.approverConfirmation?.problem, .cancelled)
        XCTAssertTrue(world.cloud.sent(.approverConfirmation, from: phone.deviceID).isEmpty)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, false)
    }

    func testTheFlagIsSetOnlyOnceCloudKitSavedTheConfirmation() async throws {
        world.cloud.failSends { $0.kind == Int64(MessageKind.approverConfirmation.rawValue) }
        world.model.startApproverConfirmation(macID: macID)
        await world.model.confirmApprover(typed: TestWorld.approverCode)
        XCTAssertEqual(world.model.approverConfirmation?.stage, .sending)
        XCTAssertEqual(world.model.approverConfirmation?.problem, .retrying)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, false)
        XCTAssertEqual(world.model.foregroundPollInterval, 2)
        world.cloud.failSends(where: nil)
        world.clock.advance(by: 2)
        await world.model.processInbox()
        XCTAssertEqual(world.model.approverConfirmation?.stage, .sent)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, true)
    }

    func testStopApprovingClearsTheFlagAndDropsTheMacsCards() async throws {
        await world.approveMac()
        let sealed = try await world.sendRequest()
        world.notifications.delivered = [PushHint(recordName: sealed.sealed.messageID.text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "request")]
        await world.model.becameActive()
        XCTAssertEqual(world.model.requests.count, 1)
        await world.model.stopApproving(macID: macID)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, false)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("request"))
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "requests from it are refused")
    }

    func testRemovingAMacOrItsUnpairNoticeDropsItsCards() async throws {
        await world.approveMac()
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        await world.model.removeMac(id: macID)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)

        let other = world.makeMac(name: "Office Mac")
        try await world.pairAndApprove(other)
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
        await world.approveMac()
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        let name = sealed.sealed.messageID.text
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: name),
                                       arrivedAt: world.clock.now(), notificationIdentifier: "tapped", opened: true)
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
    }

    func testANotificationThatIsOnlyShownOpensNothing() async throws {
        await world.approveMac()
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: sealed.sealed.messageID.text),
                                       arrivedAt: world.clock.now(), notificationIdentifier: "front")
        XCTAssertNil(world.model.openedRequest)
    }

    func testOpeningANotificationThatLaunchesTheAppOpensItsRequest() async throws {
        await world.approveMac()
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
        await world.approveMac()
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
        await world.approveMac()
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
