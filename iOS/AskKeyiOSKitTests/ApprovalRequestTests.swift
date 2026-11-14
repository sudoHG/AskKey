import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// Requests reaching the approver (#314 acceptance 1, 4 and 5).
@MainActor
final class ApprovalRequestTests: XCTestCase {
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

    // MARK: Showing a request

    func testARequestFromAnApprovedMacShowsTheCardAndIsStoredAsCiphertextFirst() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        await world.model.processInbox()

        let card = try XCTUnwrap(world.card)
        XCTAssertEqual(card.id, sealed.sealed.messageID.text)
        XCTAssertEqual(card.macName, TestWorld.macName, "the iPhone's own name for the Mac")
        XCTAssertEqual(card.display.requesterName, "Codex")
        XCTAssertEqual(card.display.credentialName, "GitHub Token")
        XCTAssertEqual(card.display.commandSummary, "./deploy.sh --prod --region eu-west-1")
        XCTAssertEqual(card.display.workingDirectory, "~/src/app")
        XCTAssertEqual(card.display.executableName, "deploy.sh")
        XCTAssertEqual(card.display.deliveryRows.map(\.variable), ["GITHUB_TOKEN"])
        XCTAssertEqual(card.phase(at: world.clock.now()), .pending)
        XCTAssertEqual(card.secondsLeft(at: world.clock.now()), 300)

        let stored = world.approvalStore.stored
        XCTAssertEqual(stored.requests.map(\.recordName), [card.id])
        XCTAssertEqual(stored.requests.first?.envelope.body, sealed.sealed.envelope.body)
        let text = String(decoding: try XCTUnwrap(world.approvalStore.storedData), as: UTF8.self)
        for plaintext in ["Codex", "GitHub Token", "deploy.sh", "GITHUB_TOKEN", "~/src/app"] {
            XCTAssertFalse(text.contains(plaintext), "the store never holds opened content: \(plaintext)")
        }
        XCTAssertTrue(world.cloud.records(in: phoneID).isEmpty, "the inbox copy is deleted once stored")
        XCTAssertEqual(world.cloud.sent(.approvalReceipt, from: phoneID).count, 1, "the app sends the receipt itself")
        XCTAssertEqual(world.notifications.removedIdentifiers, [])
    }

    func testARequestAPushNamedIsFetchedByName() async throws {
        let phoneID = try world.phone.deviceID
        let sealed = try await world.sendRequest()
        let name = sealed.sealed.messageID.text
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: phoneID, record: name), arrivedAt: world.clock.now(),
                                       notificationIdentifier: "front")
        XCTAssertEqual(world.card?.id, name)
        XCTAssertTrue(world.cloud.namedFetches.contains([name]))
        XCTAssertFalse(world.notifications.removedIdentifiers.contains("front"), "a pending request keeps its notification")
    }

    func testPullToRefreshAndTheForegroundPollFindRequests() async throws {
        XCTAssertEqual(world.model.foregroundPollInterval, 10)
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        XCTAssertEqual(world.model.foregroundPollInterval, 2, "every 2 seconds while a request is shown")
        await world.model.decide(.deny, requestID: try XCTUnwrap(world.card?.id))
        XCTAssertEqual(world.model.foregroundPollInterval, 2, "and while it waits for the Mac")
        world.clock.advance(by: 301)
        await world.model.processInbox()
        XCTAssertEqual(world.model.foregroundPollInterval, 10)
    }

    func testARequestFromAMacWithoutTheApprovalFlagIsRefused() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        let phoneID = try world.phone.deviceID
        try await world.sendRequest(from: other)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertTrue(world.cloud.records(in: phoneID).isEmpty, "refused and deleted")
        XCTAssertTrue(world.cloud.sent(.approvalReceipt, from: phoneID).isEmpty)
    }

    func testAStoreThatCannotBeWrittenKeepsTheRequestInTheInbox() async throws {
        let phoneID = try world.phone.deviceID
        world.approvalStore.writesFail = true
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertEqual(world.cloud.records(in: phoneID).count, 1, "not reported processed, so not deleted")
        world.approvalStore.writesFail = false
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        XCTAssertTrue(world.cloud.records(in: phoneID).isEmpty)
    }

    func testARequestReinsertedAfterARelaunchIsNotShownTwice() async throws {
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        try await world.deliver(sealed.sealed.envelope)
        await relaunched.becameActive()
        XCTAssertEqual(relaunched.requests.map(\.id), [sealed.sealed.messageID.text])
        XCTAssertEqual(world.approvalStore.stored.requests.count, 1)
    }

    // MARK: Closed messages and markers

    func testAnEarlyClosedMessageSuppressesItsRequest() async throws {
        let sealed = try await world.sealRequest()
        try await world.sendClosed(.expired, for: sealed)
        try await world.deliver(sealed.sealed.envelope)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "the closed message is handled first and keeps the request hidden")
        XCTAssertEqual(world.approvalStore.stored.markers.count, 1)

        let later = try await world.sealRequest()
        try await world.sendClosed(.decidedOnMac, for: later)
        await world.model.processInbox()
        try await world.deliver(later.sealed.envelope)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "a marker stored by an earlier fetch also suppresses it")
    }

    func testAClosedMessageFromAnotherSenderIsRefused() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pairAndApprove(other)
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        try await world.sendClosed(.decidedOnMac, for: sealed, from: other)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .pending)
        XCTAssertTrue(world.approvalStore.stored.markers.isEmpty)
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .closed(.decidedOnMac))
    }

    func testAClosedMessageFromAMacWithoutTheFlagIsRefused() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        let foreign = try await world.sealRequest(from: other)
        try await world.sendClosed(.expired, for: foreign, from: other)
        await world.model.processInbox()
        XCTAssertTrue(world.approvalStore.stored.markers.isEmpty)
    }

    // MARK: Card states

    func testACardPastItsCountdownExpiresAndCanNoLongerBeDecided() async throws {
        let phone = try world.phone
        try await world.sendRequest()
        await world.model.processInbox()
        let id = try XCTUnwrap(world.card?.id)
        world.clock.advance(by: 300)
        XCTAssertEqual(world.card?.phase(at: world.clock.now()), .timedOut(decided: nil))
        await world.model.decide(.deny, requestID: id)
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertTrue(phone.approvalReasons.allSatisfy { !$0.contains("GitHub Token") })
        world.clock.advance(by: 301)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty, "deleted after its transport expiry")
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
    }

    func testAShortenedDisplayOffersOnlyDenyAndSaysWhatWasShortened() async throws {
        var display = TestWorld.sampleDisplay
        display.commandLine = "./deploy.sh " + String(repeating: "x", count: 7_000)
        try await world.sendRequest(display: display, offers: .all, timedDuration: 1_800)
        await world.model.processInbox()
        let card = try XCTUnwrap(world.card)
        XCTAssertEqual(card.display.offers, .denyOnly)
        XCTAssertEqual(card.display.offeredCodes, [.deny])
        XCTAssertTrue(card.display.shortened.contains(.commandLine))
        XCTAssertTrue(card.display.commandLine.contains("…"))
        XCTAssertEqual(card.display.commandSummary.count, 160)
        await world.model.decide(.allowOnce, requestID: card.id)
        XCTAssertTrue(try world.decisionAttempts().isEmpty, "a code that was not offered is never sent")
        await world.model.decide(.deny, requestID: card.id)
        let codes = try await world.decisions().map(\.decision.code)
        XCTAssertEqual(codes, [.deny])
    }

    func testUnavailableDeliveryMetadataOffersOnlyDeny() async throws {
        var display = TestWorld.sampleDisplay
        display.deliveryMetadataUnavailable = true
        try await world.sendRequest(display: display)
        await world.model.processInbox()
        let card = try XCTUnwrap(world.card)
        XCTAssertTrue(card.display.deliveryMetadataUnavailable)
        XCTAssertTrue(card.display.deliveryRows.isEmpty)
        XCTAssertEqual(card.display.offers, .denyOnly)
    }

    func testALaterLaunchMarksOlderCardsGoneAndAnEarlierLaunchIsRefused() async throws {
        let first = try await world.sendRequest(launchTime: TestWorld.macLaunch)
        let same = try await world.sendRequest(launchTime: TestWorld.macLaunch)
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 2, "equal launch times displace nothing")
        let restarted = try await world.sendRequest(launchTime: TestWorld.macLaunch.addingTimeInterval(60))
        await world.model.processInbox()
        let now = world.clock.now()
        let phases = Dictionary(uniqueKeysWithValues: world.model.requests.map { ($0.id, $0.phase(at: now)) })
        XCTAssertEqual(phases[first.sealed.messageID.text], .gone)
        XCTAssertEqual(phases[same.sealed.messageID.text], .gone)
        XCTAssertEqual(phases[restarted.sealed.messageID.text], .pending)
        XCTAssertEqual(world.model.requests.first?.id, restarted.sealed.messageID.text, "pending cards come first")

        try await world.sendRequest(launchTime: TestWorld.macLaunch.addingTimeInterval(30))
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 3, "a request from an earlier Mac launch is refused")
    }

    func testTheCountdownCancelsTheClockOffset() async throws {
        for offset: TimeInterval in [-240, -120, 120, 240] {
            world.macClock.offset = offset
            let sealed = try await world.sendRequest(lifetime: 200)
            world.clock.advance(by: 3)
            await world.model.processInbox()
            let card = try XCTUnwrap(world.model.requests.first { $0.id == sealed.sealed.messageID.text }, "offset \(offset)")
            XCTAssertEqual(card.countdownEnd, world.clock.now().addingTimeInterval(200), "offset \(offset)")
        }
    }

    func testTheStoredCountdownSurvivesARelaunch() async throws {
        try await world.sendRequest()
        world.clock.advance(by: 10)
        await world.model.processInbox()
        let end = try XCTUnwrap(world.card?.countdownEnd)
        world.clock.advance(by: 100)
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.requests.first?.countdownEnd, end, "re-opening never starts the countdown again")
        XCTAssertEqual(relaunched.requests.first?.display.credentialName, "GitHub Token")
    }

    // MARK: Limits

    func testSixteenPendingRequestsPerMac() async throws {
        for _ in 0..<17 { try await world.sendRequest() }
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 16)
        let id = try XCTUnwrap(world.model.requests.first?.id)
        world.clock.advance(by: 301)
        await world.model.processInbox()
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.filter { !$0.phase(at: self.world.clock.now()).isFinished }.count, 1,
                       "finished cards no longer count")
        XCTAssertTrue(world.model.requests.contains { $0.id == id })
    }

    func testSixtyFourPendingRequestsInAll() async throws {
        var macs = [world.primaryMac]
        for index in 1..<5 {
            let peer = world.makeMac(name: "Mac \(index)")
            try await world.pairAndApprove(peer)
            macs.append(peer)
        }
        for peer in macs.prefix(4) {
            for _ in 0..<16 { try await world.sendRequest(from: peer) }
        }
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 64)
        try await world.sendRequest(from: macs[4])
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 64)
        XCTAssertFalse(world.model.requests.contains { $0.macID == macs[4].deviceID.text })
    }

    func testSixteenMarkersPerMac() async throws {
        for _ in 0..<17 {
            let sealed = try await world.sealRequest()
            try await world.sendClosed(.expired, for: sealed)
        }
        await world.model.processInbox()
        XCTAssertEqual(world.approvalStore.stored.markers.count, 16)
    }

    // MARK: Account and identity

    func testAnAccountChangeDropsTheStoredState() async throws {
        try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.count, 1)
        world.cloud.accountState = .available(userRecordName: "_user-b")
        await world.model.refreshAccount()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertNil(world.approvalStore.storedData)
        XCTAssertEqual(world.model.pairedMacs.first?.isApprover, true, "the flags stay")
    }

    func testSigningOutDropsTheStoredState() async throws {
        try await world.sendRequest()
        await world.model.processInbox()
        world.cloud.accountState = .noAccount
        await world.model.refreshAccount()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertNil(world.approvalStore.storedData)
    }

    func testAnIdentityResetDropsTheStoredState() async throws {
        try await world.sendRequest()
        await world.model.processInbox()
        world.identities.restoringError = .unusable
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.stage, .unusableIdentity)
        XCTAssertNotNil(world.approvalStore.storedData)
        await relaunched.resetIdentity()
        XCTAssertNil(world.approvalStore.storedData)
        XCTAssertTrue(relaunched.requests.isEmpty)
    }
}
