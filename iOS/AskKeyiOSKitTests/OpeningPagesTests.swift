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
        world.cloud.callHook = nil
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

    /// Each case starts from a closed sheet, so the page checked is the
    /// one this tap opened.
    func testNoTextFromTheNotificationReachesAnyOpenedPage() async throws {
        let phone = try world.phone.deviceID
        func check(_ phase: OpeningPhase?, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotNil(model.openedRequest, file: file, line: line)
            XCTAssertEqual(model.openingPhase(at: now), phase, file: file, line: line)
            XCTAssertFalse(viewState(of: model).contains(Self.canary), file: file, line: line)
            model.openedRequest = nil
            model.opening = nil
        }
        // A request the app verifies: its card shows the request's own text.
        let real = try await world.sendRequest().sealed.messageID.text
        await tap(real)
        XCTAssertNotNil(model.card(real))
        check(nil)
        // Loading, slow and failed, while CloudKit asks to wait.
        let waiting = try await world.sendRequest(launchTime: TestWorld.macLaunch).sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 60)
        world.cloud.zoneFetchesFail = true
        await tap(waiting)
        for (seconds, phase) in [(0.0, OpeningPhase.loading), (3.5, .slow), (12, .failed)] {
            world.clock.advance(by: seconds)
            XCTAssertEqual(model.openingPhase(at: now), phase)
            XCTAssertFalse(viewState(of: model).contains(Self.canary))
        }
        check(.failed)
        world.cloud.namedFetchError = nil
        world.cloud.zoneFetchesFail = false
        world.clock.advance(by: 60)
        // A record that is not there: ended, without an outcome.
        await tap(MessageID.random().text)
        check(.ended(nil))
        // A finished request the app holds without a card: ended, with how.
        let sealed = try await world.sendRequest()
        await model.processInbox()
        let held = sealed.sealed.messageID.text
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await model.processInbox()
        try hideCard(held)
        await tap(held)
        check(.ended(EndedRequest(ending: .closed(.decidedOnMac), macName: TestWorld.macName)))
        // A name that is not a message ID, in the extension's key and in a
        // CloudKit push: unverified, without the name.
        await tap("\(Self.canary) wants Prod Token")
        check(.unverified)
        var push = TestWorld.alertPush(for: phone, record: "\(Self.canary)-record")
        push["aps"] = ["alert": ["title": Self.canary, "body": Self.canary]]
        await model.receivedPush(userInfo: push, arrivedAt: now, notificationIdentifier: "ck", opened: true)
        check(.unverified)
        // The same at launch.
        let launched = AppModel(environment: world.environment)
        await launched.receivedPush(userInfo: push, arrivedAt: now, notificationIdentifier: "ck", opened: true)
        await launched.start()
        XCTAssertEqual(launched.openingPhase(at: now), .unverified)
        XCTAssertFalse(viewState(of: launched).contains(Self.canary))
        // A refused request: unverified.
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.storeWithoutApprovalFlag(other)
        await tap(try await world.sendRequest(from: other).sealed.messageID.text)
        check(.unverified)
    }

    /// Hides a finished request's card, as an earlier build let the person
    /// dismiss it; the app still holds the request.
    private func hideCard(_ name: String) throws {
        let index = try XCTUnwrap(model.approvals.index(of: name))
        model.approvals.requests[index].dismissed = true
        model.rebuildRequests()
        XCTAssertNil(model.card(name))
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
            try hideCard(name)
            await tap(name)
            let expected = EndedRequest(ending: ending, macName: TestWorld.macName)
            XCTAssertEqual(model.openingPhase(at: now), .ended(expected))
            guard case .ended(let shown?)? = model.openingPhase(at: now) else { return XCTFail("no outcome") }
            XCTAssertEqual(shown.ending.tone, tone, "the outcome page's color")
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

    /// A record refused on another path is gone when its own fetch runs;
    /// the page still says it could not be verified (review of #364).
    func testAZonePollThatRefusesTheTappedRecordShowsUnverified() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.storeWithoutApprovalFlag(other)
        let name = try await world.sendRequest(from: other).sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 30)
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .unverified, "the pass's zone poll refused it")
        world.cloud.namedFetchError = nil
        world.clock.advance(by: 31)
        await model.processInbox()
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
    }

    func testARecordRefusedBeforeTheTapShowsUnverified() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.storeWithoutApprovalFlag(other)
        let name = try await world.sendRequest(from: other).sealed.messageID.text
        await model.processInbox()
        XCTAssertTrue(world.cloud.records(in: try world.phone.deviceID).isEmpty, "refused and deleted")
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
    }

    func testARecordCloudKitAsksToWaitForIsNoFailure() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedRecordsRetryAfter = 30
        world.cloud.zoneFetchesFail = true
        await tap(name)
        XCTAssertEqual(model.openingPhase(at: now), .loading)
        world.cloud.namedRecordsRetryAfter = nil
        world.clock.advance(by: 31)
        await model.processInbox()
        XCTAssertEqual(model.requests.map(\.id), [name])
    }

    /// Only a pass whose zone poll started after the failure of the same
    /// tap or Try Again shows the failed page.
    func testOnlyAPassAfterTheSameAttemptsFailureShowsFailed() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 60)
        world.cloud.zoneFetchesFail = true
        await tap(name)
        let first = try XCTUnwrap(model.opening?.attempt)
        world.clock.advance(by: 1)
        model.opening?.since = now
        model.opening?.fetchFailed = true
        model.settleOpening(after: [:], failedAttempt: first)
        XCTAssertEqual(model.openingPhase(at: now), .loading, "that pass started before this attempt")
        model.settleOpening(after: [:], failedAttempt: model.opening?.attempt)
        XCTAssertEqual(model.openingPhase(at: now), .failed)
    }

    func testThePageChangesAtTheDatesItSchedules() {
        let tapped = Date(timeIntervalSince1970: 1_800_000_000.123)
        let opening = OpeningRequest(id: "record", since: tapped, step: .fetching)
        let dates = opening.changeDates
        XCTAssertFalse(opening.showsPlaceholder(at: dates[0].addingTimeInterval(-0.001)))
        XCTAssertTrue(opening.showsPlaceholder(at: dates[0]))
        XCTAssertEqual(opening.phase(at: dates[1].addingTimeInterval(-0.001)), .loading)
        XCTAssertEqual(opening.phase(at: dates[1]), .slow)
        XCTAssertEqual(opening.phase(at: dates[2].addingTimeInterval(-0.001)), .slow)
        XCTAssertEqual(opening.phase(at: dates[2]), .failed)
    }

    /// Controller's decision on #364: a request refused as expired ended,
    /// as far as the app knows; the page takes nothing from the record.
    func testATappedRequestThatExpiredShowsEndedWithNothingFromTheRecord() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.clock.advance(by: 3_600)
        await tap(name)
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil), "the generic sentence")
        XCTAssertFalse(viewState(of: model).contains(Self.canary))
    }

    /// Decided on the Mac before the tap: the pass ends the request (its
    /// closed message came first) while its own fetch still finds the
    /// record, which the messenger then refuses as a repeat.
    func testATappedRequestAPassAlreadyHandledShowsEnded() async throws {
        let sealed = try await world.sealRequest()
        let name = sealed.sealed.messageID.text
        try await world.deliver(sealed.sealed.envelope)
        try await world.sendClosed(.decidedOnMac, for: sealed)
        let (gate, armed) = try holdDeletion(of: name)
        let pass = Task { await self.model.processInbox() }
        await waitUntil { !armed.value }
        let tapped = Task { await self.tap(name) }
        await waitUntil { if case .ended? = self.model.opening?.step { true } else { false } }
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil), "not unverified")
        gate.open()
        await pass.value
        await tapped.value
        XCTAssertEqual(model.openingPhase(at: now), .ended(nil))
        XCTAssertTrue(model.requests.isEmpty)
    }

    /// The pass refuses the record while its own fetch finds it handled:
    /// the pass's refusal wins.
    func testARecordAPassRefusesStaysUnverifiedWhenItsOwnFetchFindsItHandled() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        try await world.storeWithoutApprovalFlag(other)
        let name = try await world.sendRequest(from: other).sealed.messageID.text
        let (gate, armed) = try holdDeletion(of: name)
        let pass = Task { await self.model.processInbox() }
        await waitUntil { !armed.value }
        let tapped = Task { await self.tap(name) }
        await waitUntil { self.model.opening.map { $0.step != .fetchDue && $0.step != .fetching } ?? false }
        gate.open()
        await pass.value
        await tapped.value
        XCTAssertEqual(model.openingPhase(at: now), .unverified)
    }

    /// Holds the phone's first deletion of `name` until the gate opens.
    private func holdDeletion(of name: String) throws -> (TestGate, Box<Bool>) {
        let phone = try world.phone.deviceID.text
        let gate = TestGate()
        let armed = Box(true)
        world.cloud.callHook = { call in
            guard call.device == phone, armed.value, case .delete(let names) = call.kind, names.contains(name) else { return }
            armed.value = false
            await gate.wait()
        }
        return (gate, armed)
    }

    /// Waits up to five seconds for work running in other tasks.
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<5_000 where !condition() { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
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

/// Holds a caller until the test opens it.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let resumed = lock.withLock {
            opened = true
            defer { waiting = [] }
            return waiting
        }
        resumed.forEach { $0.resume() }
    }
}
