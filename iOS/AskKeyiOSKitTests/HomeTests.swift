import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// The home's tabs (#346): which requests the Requests tab lists and its
/// badge counts, a request arriving in front, the notification
/// authorization behind the banner, and this iPhone's status.
@MainActor
final class HomeTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
    }

    override func tearDown() async throws {
        world = nil
    }

    private var now: Date { world.clock.now() }

    private func recordName(_ sealed: SealedApprovalRequest) -> String {
        sealed.sealed.messageID.text
    }

    // MARK: Requests and the badge

    /// Decision 7 of #344: a request the Mac closed or whose countdown ended
    /// leaves the tab; one whose decision was sent stays until the Mac
    /// closes it. The badge counts only those that can still be decided.
    func testTheRequestsTabListsOnlyRequestsThatCanStillBeDecidedOrWaitForTheMac() async throws {
        let decidedOnMac = try await world.sendRequest()
        let denied = try await world.sendRequest()
        let pending = try await world.sendRequest(lifetime: 120)
        await world.model.processInbox()
        XCTAssertEqual(Set(world.model.activeRequests(at: now).map(\.id)),
                       Set([decidedOnMac, denied, pending].map(recordName)))
        XCTAssertEqual(world.model.decidableRequestCount(at: now), 3)

        try await world.sendClosed(.decidedOnMac, for: decidedOnMac)
        await world.model.decide(.deny, requestID: recordName(denied))
        await world.model.processInbox()
        XCTAssertEqual(world.model.activeRequests(at: now).map(\.id), [recordName(pending), recordName(denied)],
                       "by time left; the sent decision waits for the Mac")
        XCTAssertEqual(world.model.decidableRequestCount(at: now), 1)
        XCTAssertEqual(world.model.requests.count, 3, "a finished request's page can still show it")

        world.clock.advance(by: 130)
        XCTAssertEqual(world.model.activeRequests(at: now).map(\.id), [recordName(denied)])
        XCTAssertEqual(world.model.decidableRequestCount(at: now), 0)

        try await world.sendClosed(.applied, code: .deny, for: denied)
        await world.model.processInbox()
        XCTAssertTrue(world.model.activeRequests(at: now).isEmpty)
    }

    /// The badge changes when a countdown ends, so the home redraws then.
    func testTheBadgeIsRedrawnWhenAnUndecidedCountdownEnds() async throws {
        try await world.sendRequest(lifetime: 120)
        let decided = try await world.sendRequest()
        await world.model.processInbox()
        await world.model.decide(.deny, requestID: recordName(decided))
        let pending = try XCTUnwrap(world.model.requests.first { $0.decision == nil })
        XCTAssertEqual(world.model.decidableCountChanges, [pending.countdownEnd])
    }

    /// A card fetched by name for a tapped notification cannot be decided
    /// until the zone poll after that fetch ran (#337), so the badge leaves
    /// it out while the row still lists it.
    func testTheBadgeLeavesOutACardStillBeingChecked() throws {
        let display = RequestDisplay(requesterName: "Codex", purpose: "", credentialName: "GitHub Token",
                                     commandLine: "./deploy.sh", workingDirectory: "", executableName: "deploy.sh",
                                     deliveryRows: [])
        func card(_ id: String, isChecking: Bool) -> RequestCard {
            RequestCard(id: id, macID: "mac", macName: TestWorld.macName, macPairedAt: now, display: display,
                        countdownEnd: now.addingTimeInterval(200), isChecking: isChecking)
        }
        world.model.requests = [card("checking", isChecking: true), card("checked", isChecking: false)]
        XCTAssertEqual(world.model.activeRequests(at: now).count, 2)
        XCTAssertEqual(world.model.decidableRequestCount(at: now), 1)
    }

    /// Decision 8 of #344: in front, the notification shows as a banner, the
    /// badge counts the request, and neither its page nor the tab changes.
    func testARequestArrivingInFrontNeverOpensItsPage() async throws {
        XCTAssertEqual(AskKeyAppDelegate.foregroundPresentation, [.banner, .list, .sound])
        world.model.selectedTab = .macs
        let sealed = try await world.sendRequest()
        await world.model.receivedPush(userInfo: TestWorld.alertPush(for: try world.phone.deviceID,
                                                                     record: recordName(sealed)),
                                       arrivedAt: now, notificationIdentifier: "arrived")
        XCTAssertEqual(world.model.activeRequests(at: now).map(\.id), [recordName(sealed)])
        XCTAssertEqual(world.model.decidableRequestCount(at: now), 1)
        XCTAssertNil(world.model.openedRequest)
        XCTAssertNil(world.model.opening)
        XCTAssertEqual(world.model.selectedTab, .macs)
    }

    /// A request that arrives is highlighted, whichever tab shows, until the
    /// Requests tab has shown it; one that leaves is no longer highlighted.
    func testAnArrivingRequestIsHighlightedUntilTheRequestsTabShowsIt() async throws {
        world.model.selectedTab = .macs
        let first = try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.unseenArrivals, [recordName(first)])
        world.model.markArrivalsSeen([recordName(first)])
        XCTAssertTrue(world.model.unseenArrivals.isEmpty)

        let second = try await world.sendRequest()
        await world.model.processInbox()
        XCTAssertEqual(world.model.unseenArrivals, [recordName(second)])
        await world.model.removeMac(id: world.macIdentity.deviceID.text)
        XCTAssertTrue(world.model.unseenArrivals.isEmpty, "a dropped request is not highlighted")
    }

    /// Requests reopened at launch did not just arrive.
    func testRequestsReopenedAtLaunchAreNotHighlighted() async throws {
        try await world.sendRequest()
        await world.model.processInbox()
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.requests.count, 1)
        XCTAssertTrue(relaunched.unseenArrivals.isEmpty)
    }

    /// Tapping a row opens that request's page with its card at once.
    func testOpeningARowShowsItsCard() async throws {
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        world.model.open(recordName(sealed))
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: recordName(sealed)))
        XCTAssertNil(world.model.opening, "the card exists, so nothing loads")
    }

    // MARK: Banners and this iPhone

    func testTheNotificationAuthorizationIsReadAtLaunchAndWhenTheAppBecomesActive() async throws {
        XCTAssertEqual(world.model.notificationAuthorization, .allowed)
        XCTAssertFalse(world.model.notificationsOff)
        world.notifications.authorizationState = .denied
        await world.model.sceneBecameActive()
        XCTAssertTrue(world.model.notificationsOff)
        let relaunched = AppModel(environment: world.environment)
        await relaunched.start()
        XCTAssertEqual(relaunched.notificationAuthorization, .denied)
        world.notifications.authorizationState = .allowed
        await world.model.sceneBecameActive()
        XCTAssertFalse(world.model.notificationsOff)
    }

    /// The banner shows only when notifications were turned off; the This
    /// iPhone row says On only when they are allowed.
    func testOnlyAllowedNotificationsShowAsOn() async {
        world.notifications.authorizationState = .notDetermined
        await world.model.sceneBecameActive()
        XCTAssertFalse(world.model.notificationsOff, "Settings has no switch to send the person to yet")
        XCTAssertEqual(MacsContent.notificationsOn(.allowed), true)
        XCTAssertEqual(MacsContent.notificationsOn(.denied), false)
        XCTAssertEqual(MacsContent.notificationsOn(.notDetermined), false)
        XCTAssertNil(MacsContent.notificationsOn(nil))
    }

    func testTheWelcomeReadsTheAnswerToItsNotificationPrompt() async {
        let fresh = TestWorld()
        fresh.notifications.authorizationState = .denied
        await fresh.setUpPhone()
        XCTAssertEqual(fresh.notifications.authorizationRequests, 1)
        XCTAssertTrue(fresh.model.notificationsOff)
    }

    /// While a banner shows, the empty state's capsule says the Macs cannot
    /// reach this iPhone.
    /// A long requester or Mac name is shortened in the row only.
    func testARowShortensLongNamesSoTheCredentialStaysVisible() {
        XCTAssertEqual(RequestRow.short("Codex"), "Codex")
        let long = String(repeating: "a", count: 60)
        XCTAssertEqual(RequestRow.short(long).count, 24)
        XCTAssertTrue(RequestRow.short(long).hasSuffix("…"))
    }

    func testTheTimeLeftIsSpokenAsADuration() {
        XCTAssertEqual(RequestRow.spoken(272, locale: Locale(identifier: "en")), "4 minutes, 32 seconds")
    }

    /// Only an iCloud banner makes the capsule say the Macs cannot reach
    /// this iPhone; notifications off leave it counting the Macs, and it is
    /// hidden without an approving Mac.
    func testTheCapsuleSaysUnreachableOnlyWhileAnICloudBannerShows() {
        XCTAssertEqual(RequestsContent.capsule(accountNotice: nil, approvingMacs: 2), .reachable(2))
        XCTAssertEqual(RequestsContent.capsule(accountNotice: nil, approvingMacs: 1), .reachable(1))
        XCTAssertNil(RequestsContent.capsule(accountNotice: nil, approvingMacs: 0))
        for notice in [AccountNotice.signedOut, .restricted, .unavailable] {
            XCTAssertEqual(RequestsContent.capsule(accountNotice: notice, approvingMacs: 2), .unreachable)
            XCTAssertEqual(RequestsContent.capsule(accountNotice: notice, approvingMacs: 0), .unreachable)
        }
    }

    func testTheApprovingMacCountLeavesOutAMacWithoutTheFlag() async throws {
        XCTAssertEqual(world.model.approvingMacCount, 1)
        try await world.pair(world.makeMac(name: "Office Mac"))
        XCTAssertEqual(world.model.approvingMacCount, 2)
        try await world.storeWithoutApprovalFlag()
        XCTAssertEqual(world.model.pairedMacs.count, 2)
        XCTAssertEqual(world.model.approvingMacCount, 1)
    }

    func testTheLastDeliveryCheckIsTheLatestAnswered() async throws {
        XCTAssertNil(world.model.lastDeliveryCheck)
        let phoneID = try world.phone.deviceID
        _ = try await world.mac.sendDeliveryCheck(to: phoneID)
        world.clock.advance(by: 3)
        await world.model.becameActive()
        XCTAssertEqual(world.model.lastDeliveryCheck, now)
    }

    func testTheFootnoteNamesTouchIDOnATouchIDPhone() async {
        XCTAssertEqual(world.model.biometryKind, .faceID)
        let touch = TestWorld()
        touch.biometry.current = .enrolled(.touchID)
        await touch.setUpPhone()
        XCTAssertEqual(touch.model.biometryKind, .touchID)
    }
}
