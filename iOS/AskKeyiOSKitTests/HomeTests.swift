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

    func testTheWelcomeReadsTheAnswerToItsNotificationPrompt() async {
        let fresh = TestWorld()
        fresh.notifications.authorizationState = .denied
        await fresh.setUpPhone()
        XCTAssertEqual(fresh.notifications.authorizationRequests, 1)
        XCTAssertTrue(fresh.model.notificationsOff)
    }

    /// While a banner shows, the empty state's capsule says the Macs cannot
    /// reach this iPhone.
    func testTheCapsuleFollowsTheBanners() {
        XCTAssertFalse(RequestsContent.macsCannotReach(accountNotice: nil, notificationsOff: false))
        XCTAssertTrue(RequestsContent.macsCannotReach(accountNotice: nil, notificationsOff: true))
        for notice in [AccountNotice.signedOut, .restricted, .unavailable] {
            XCTAssertTrue(RequestsContent.macsCannotReach(accountNotice: notice, notificationsOff: false))
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
