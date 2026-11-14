import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// Revocation, account changes and storage failures that interleave with
/// sending, polling and launching.
@MainActor
final class ApprovalRaceTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        await world.approveMac()
    }

    override func tearDown() async throws {
        world = nil
    }

    private var macID: String { world.macIdentity.deviceID.text }
    private static let decisionKind = Int64(MessageKind.approvalDecision.rawValue)

    private func receive() async throws -> String {
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        return sealed.sealed.messageID.text
    }

    func testStopApprovingDuringASendKeepsTheNextStoredDecisionFromLeaving() async throws {
        let first = try await receive()
        let second = try await receive()
        world.cloud.failSends { $0.kind == Self.decisionKind }
        await world.model.decide(.allowOnce, requestID: first)
        await world.model.decide(.allowOnce, requestID: second)
        XCTAssertEqual(try world.decisionAttempts().count, 2)
        world.cloud.failSends(where: nil)
        let fired = Box(false)
        world.cloud.sendHook = { [model = world.model, macID] envelope in
            guard envelope.kind == Self.decisionKind, !fired.value else { return }
            fired.value = true
            _ = await model.stopApproving(macID: macID)
        }
        world.clock.advance(by: 2)
        await world.model.processInbox()
        XCTAssertTrue(fired.value)
        XCTAssertEqual(try world.decisionAttempts().count, 3, "only the decision already being sent left")
        XCTAssertTrue(world.model.requests.isEmpty)
    }

    func testTheDecisionIsStoredBeforeItsFirstSend() async throws {
        let id = try await receive()
        let storedAtSend = Box<Bool?>(nil)
        world.cloud.sendHook = { [store = world.approvalStore] envelope in
            guard envelope.kind == Self.decisionKind else { return }
            storedAtSend.value = store.stored.requests.first?.decision?.envelope.body == envelope.body
        }
        await world.model.decide(.deny, requestID: id)
        XCTAssertEqual(storedAtSend.value, true)
    }

    func testAStaleMessengerCannotStoreARequestAfterAnAccountChange() async throws {
        let services = try XCTUnwrap(world.model.services)
        let sealed = try await world.sealRequest()
        let list = try await services.registry.list()
        guard case .approval(let message) = try DeviceMessageVerifier(identity: try world.phone, list: list)
            .verify(sealed.sealed.envelope, now: world.clock.now()) else { return XCTFail("the request should verify") }
        world.cloud.accountState = .available(userRecordName: "_user-b")
        await world.model.refreshAccount()
        XCTAssertEqual(services.generation, 1)
        let stale = await world.model.handleApproval(message, generation: 0)
        XCTAssertEqual(stale, .failed)
        XCTAssertTrue(world.model.requests.isEmpty)
        let current = await world.model.handleApproval(message, generation: 1)
        XCTAssertEqual(current, .processed)
    }

    func testAStateSavedUnderAnotherAccountIsDroppedAtLaunch() async throws {
        _ = try await receive()
        XCTAssertNotNil(world.approvalStore.storedData)
        // The account changed, and deleting the stored state failed.
        world.localState.inboxPosition = InboxPosition(userRecordName: "_user-b", token: nil)
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertTrue(relaunched.requests.isEmpty)
        XCTAssertNil(world.approvalStore.storedData)
    }

    func testAStoreThatCannotBeReadIsNeverOverwritten() async throws {
        _ = try await receive()
        let stored = try XCTUnwrap(world.approvalStore.storedData)
        world.approvalStore.readsFail = true
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        try await world.sendRequest()
        await relaunched.becameActive()
        XCTAssertTrue(relaunched.requests.isEmpty)
        XCTAssertEqual(world.approvalStore.storedData, stored, "nothing is written over the unreadable state")
        XCTAssertEqual(world.cloud.records(in: try world.phone.deviceID).count, 1, "the new request stays in the inbox")
        world.approvalStore.readsFail = false
        await relaunched.processInbox()
        await relaunched.processInbox()
        XCTAssertEqual(relaunched.requests.count, 2)
    }

    func testAFailingInboxDoesNotStopADueDecisionFromBeingResent() async throws {
        let id = try await receive()
        world.cloud.failSends { $0.kind == Self.decisionKind }
        await world.model.decide(.deny, requestID: id)
        world.cloud.failSends(where: nil)
        world.cloud.zoneFetchesFail = true
        world.clock.advance(by: 2)
        await world.model.processInbox()
        XCTAssertEqual(try world.decisionAttempts().count, 2)
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .waiting(.deny))
    }

    func testADenyMadeWhileICloudCannotAnswerIsStoredAndSentLater() async throws {
        let id = try await receive()
        world.cloud.accountState = .temporarilyUnavailable
        world.cloud.failSends { $0.kind == Self.decisionKind }
        await world.model.decide(.deny, requestID: id)
        XCTAssertNil(world.model.decisionProblems[id])
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .sending(.deny))
        world.cloud.accountState = .available(userRecordName: "_user-a")
        world.cloud.failSends(where: nil)
        world.clock.advance(by: 2)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .waiting(.deny))
    }

    func testAnIdentityErrorWhileReopeningKeepsTheStoredState() async throws {
        _ = try await receive()
        let stored = try XCTUnwrap(world.approvalStore.storedData)
        let phone = try world.phone
        phone.isUnusable = true
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.stage, .unusableIdentity)
        XCTAssertEqual(world.approvalStore.storedData, stored)
    }

    func testStopApprovingReportsAFlagThatCouldNotBeCleared() async throws {
        world.keychain.writesFail = true
        let stopped = await world.model.stopApproving(macID: macID)
        XCTAssertFalse(stopped)
        world.keychain.writesFail = false
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "this process refuses the Mac's requests anyway")
    }

    func testStoredRequestsAreCappedPerMacFinishedOnesIncluded() async throws {
        for _ in 0..<2 {
            var sealed: [SealedApprovalRequest] = []
            for _ in 0..<16 { sealed.append(try await world.sendRequest()) }
            await world.model.processInbox()
            for request in sealed { try await world.sendClosed(.decidedOnMac, for: request) }
            await world.model.processInbox()
        }
        XCTAssertEqual(world.approvalStore.stored.requests.count, 32)
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.approvalStore.stored.requests.count, 32)
    }

    // MARK: Notifications

    func testANotificationOfARequestDeletedAtLaunchIsRemoved() async throws {
        let id = try await receive()
        world.clock.advance(by: 601)
        world.notifications.delivered = [PushHint(recordName: id, arrivedAt: world.clock.now().addingTimeInterval(-500),
                                                  notificationIdentifier: "old")]
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        await relaunched.becameActive()
        XCTAssertTrue(world.notifications.removedIdentifiers.contains("old"))
    }

    func testEveryNotificationOfARequestIsRemovedWhenItSettles() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        let id = sealed.sealed.messageID.text
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: id), arrivedAt: world.clock.now(),
                                       notificationIdentifier: nil)
        world.notifications.delivered = [
            PushHint(recordName: id, arrivedAt: world.clock.now(), notificationIdentifier: "first"),
            PushHint(recordName: id, arrivedAt: world.clock.now(), notificationIdentifier: "second"),
        ]
        await world.model.becameActive()
        XCTAssertEqual(world.model.requests.count, 1)
        try await world.sendClosed(.expired, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(Set(world.notifications.removedIdentifiers), ["first", "second"])
    }

    func testAnAccountChangeWhileAConfirmationIsSendingResetsTheSheet() async throws {
        world.cloud.failSends { $0.kind == Int64(MessageKind.approverConfirmation.rawValue) }
        world.model.startApproverConfirmation(macID: macID)
        await world.model.confirmApprover(typed: TestWorld.approverCode)
        XCTAssertEqual(world.model.approverConfirmation?.stage, .sending)
        world.cloud.accountState = .available(userRecordName: "_user-b")
        await world.model.refreshAccount()
        XCTAssertEqual(world.model.approverConfirmation?.stage, .entering)
        XCTAssertEqual(world.model.approverConfirmation?.problem, .notSent)
    }
}
