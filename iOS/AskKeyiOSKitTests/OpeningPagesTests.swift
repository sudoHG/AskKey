import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// The pages of a tapped notification's request before its card (#348):
/// loading, slow, failed with Try Again, ended and unverified. Nothing from
/// the notification reaches them.
@MainActor
final class OpeningPagesTests: XCTestCase {
    private var world: TestWorld!
    private static let canary = "Zq7-CANARY"

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        await world.model.processInbox()
    }

    override func tearDown() async throws {
        world = nil
    }

    private var model: AppModel { world.model }
    private var now: Date { world.clock.now() }

    /// Taps the extension's notification for `name`, whose alert says
    /// something no verified request says.
    private func tap(_ name: String, on model: AppModel? = nil) async {
        await (model ?? world.model).receivedPush(userInfo: Self.alert(name: name), arrivedAt: now,
                                                  notificationIdentifier: "tapped", opened: true)
    }

    private static func alert(name: String) -> [AnyHashable: Any] {
        ["aps": ["alert": ["title": "\(canary) wants Prod Token", "body": "on \(canary) Mac"]],
         PushHintReader.extensionRecordNameKey: name]
    }

    private func namedFetches() throws -> [String] {
        try world.cloud.calls(by: world.phone.deviceID).flatMap { call -> [String] in
            if case .namedFetch(let names) = call { return names }
            return []
        }
    }

    /// Everything the sheet's view is built from.
    private func viewState(of model: AppModel) -> String {
        var text = ""
        dump(model.openedRequest, to: &text)
        dump(model.opening, to: &text)
        dump(model.openingPhase(at: now), to: &text)
        dump(model.openingShowsPlaceholder(at: now), to: &text)
        dump(model.requests, to: &text)
        return text
    }

    // MARK: Nothing from the notification

    func testNoTextFromTheNotificationReachesAnyOpenedPage() async throws {
        let phone = try world.phone.deviceID
        // A request the app verifies: its card shows the request's own text.
        let real = try await world.sendRequest().sealed.messageID.text
        await tap(real)
        XCTAssertNotNil(model.card(real))
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
        // A record that is not there: ended, without an outcome.
        await tap(MessageID.random().text)
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil))
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
        // A name that is not a message ID, in the extension's key and in a
        // CloudKit push: unverified, without the name.
        await tap("\(Self.canary) wants Prod Token")
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
        var push = TestWorld.alertPush(for: phone, record: "\(Self.canary)-record")
        push["aps"] = ["alert": ["title": Self.canary, "body": Self.canary]]
        await model.receivedPush(userInfo: push, arrivedAt: now, notificationIdentifier: "ck", opened: true)
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
        // A refused request: unverified.
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.storeWithoutApprovalFlag(other)
        await tap(try await world.sendRequest(from: other).sealed.messageID.text)
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
    }

    // MARK: Loading, slow, failed

    func testThePlaceholderWaitsAThirdOfASecondAndSlowsAtThreeSeconds() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 60)
        world.cloud.zoneFetchesFail = true
        let tapped = now
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: tapped), .loading, "asking to wait is no failure")
        XCTAssertFalse(model.openingShowsPlaceholder(at: tapped), "the sheet opens with its frame only")
        world.clock.advance(by: 0.29)
        XCTAssertFalse(model.openingShowsPlaceholder(at: now))
        world.clock.advance(by: 0.02)
        XCTAssertTrue(model.openingShowsPlaceholder(at: now))
        XCTAssertEqual(model.openingPhase(at: now), .loading)
        world.clock.advance(by: 2.68)
        XCTAssertEqual(model.openingPhase(at: now), .loading)
        world.clock.advance(by: 0.02)
        XCTAssertEqual(model.openingPhase(at: now), .slow)
        world.clock.advance(by: 11.98)
        XCTAssertEqual(model.openingPhase(at: now), .slow)
        world.clock.advance(by: 0.02)
        XCTAssertEqual(model.openingPhase(at: now), .failed, "nothing settled within 15 seconds")
        XCTAssertEqual(model.foregroundPollInterval, 2, "the record is still fetched by name")
    }

    func testAFailedFetchAndAPassWithoutTheCardShowFailed() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .networkUnavailable
        world.cloud.zoneFetchesFail = true
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .failed, "the pass after the failed fetch found no card")
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name))
    }

    func testTryAgainFetchesTheRecordAgainAndShowsTheCard() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .networkUnavailable
        world.cloud.zoneFetchesFail = true
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .failed)
        world.cloud.namedFetchError = nil
        world.cloud.clearCalls()
        await model.retryOpening()
        XCTAssertEqual(try namedFetches(), [name], "fetched by name again; the zone poll still fails")
        XCTAssertEqual(model.requests.map(\.id), [name])
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(model.opening)
    }

    func testTryAgainStillHonorsRetryAfter() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 30)
        world.cloud.zoneFetchesFail = true
        await tap(name)
        world.clock.advance(by: 16)
        XCTAssertEqual(model.openingPhase(at: now), .failed)
        world.cloud.namedFetchError = nil
        world.cloud.clearCalls()
        await model.retryOpening()
        XCTAssertEqual(model.openingPhase(at: now), .loading, "the page loads again")
        XCTAssertFalse(model.openingShowsPlaceholder(at: now), "its timers start over")
        XCTAssertTrue(try namedFetches().isEmpty, "CloudKit asked to wait")
        world.clock.advance(by: 15)
        await model.processInbox()
        XCTAssertEqual(try namedFetches(), [name])
        XCTAssertEqual(model.requests.map(\.id), [name])
        XCTAssertNil(model.opening)
    }

    func testTryAgainDoesNothingWhileLoading() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 30)
        await tap(name)
        let opening = model.opening
        world.clock.advance(by: 1)
        await model.retryOpening()
        XCTAssertEqual(model.opening, opening)
    }

    // MARK: Ended

    func testARequestAClosedMessageAlreadyEndedShowsEndedWithoutAnOutcome() async throws {
        let sealed = try await world.sealRequest()
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await model.processInbox()
        try await world.deliver(sealed.sealed.envelope)
        await tap(sealed.sealed.messageID.text)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil), "a marker keeps no outcome")
    }

    /// A finished request the app holds without a card says how it ended,
    /// with the outcome page's symbol and color.
    func testAStoredFinishedRequestShowsHowItEnded() async throws {
        let cases: [(ApprovalDecisionCode?, ApprovalClosedOutcome, RequestEnding, EndingTone)] = [
            (.allowOnce, .applied, .closed(.allowedOnce), .allowed),
            (.deny, .applied, .closed(.denied), .denied),
            (nil, .decidedOnMac, .closed(.decidedOnMac), .neutral),
        ]
        for (code, outcome, ending, tone) in cases {
            let sealed = try await world.sendRequest()
            await model.processInbox()
            let name = sealed.sealed.messageID.text
            if let code { await model.decide(code, requestID: name) }
            try await world.sendClosed(outcome, code: code, for: sealed)
            await model.processInbox()
            XCTAssertEqual(model.card(name)?.phase(at: now).ending, ending)
            // An earlier build let the person dismiss a finished card.
            let index = try XCTUnwrap(model.approvals.index(of: name))
            model.approvals.requests[index].dismissed = true
            model.rebuildRequests()
            XCTAssertNil(model.card(name))
            await tap(name)
            let expected = EndedRequest(ending: ending, macName: TestWorld.macName)
            XCTAssertEqual(model.openingPhase(at: now), .ended(expected))
            XCTAssertEqual(expected.ending.tone, tone)
            model.openedRequest = nil
        }
    }

    func testViewHistoryClosesThePageAndShowsTheHistoryTab() async {
        await tap(MessageID.random().text)
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil))
        model.showHistory()
        XCTAssertNil(model.openedRequest)
        XCTAssertEqual(model.selectedTab, .history)
    }

    // MARK: Unverified

    func testAnUnreadableNameTappedAtLaunchShowsUnverified() async {
        let launched = AppModel(environment: world.environment)
        await launched.receivedPush(userInfo: [PushHintReader.extensionRecordNameKey: 42], arrivedAt: now,
                                    notificationIdentifier: "opened", opened: true)
        await launched.start()
        XCTAssertEqual(launched.openedRequest, OpenedRequest(id: OpeningRequest.unverifiedID))
        XCTAssertEqual(launched.openingPhase(at: now), .unverified)
    }

    func testAnotherDevicesPushWithoutTheExtensionsNameOpensNothing() async {
        let other = DeviceID(rawValue: Data(repeating: 9, count: 16))!
        await model.receivedPush(userInfo: TestWorld.alertPush(for: other, record: MessageID.random().text),
                                 arrivedAt: now, notificationIdentifier: "foreign", opened: true)
        XCTAssertNil(model.openedRequest)
    }

    // MARK: A later card

    func testALaterCardReplacesEnded() async throws {
        let sealed = try await world.sealRequest()
        let name = sealed.sealed.messageID.text
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil), "not in the inbox yet")
        try await world.deliver(sealed.sealed.envelope)
        await model.processInbox()
        XCTAssertEqual(model.card(name)?.phase(at: now), .pending)
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(model.opening)
    }

    /// A refused record never comes back under its name, since the
    /// messenger refuses a replay; whatever brings a verified card for the
    /// name still replaces the page.
    func testALaterCardReplacesUnverified() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        model.open(name)
        model.opening?.step = .unverified
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
        await model.processInbox()
        XCTAssertEqual(model.card(name)?.phase(at: now), .pending)
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(model.opening)
    }
}
