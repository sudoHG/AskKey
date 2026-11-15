import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// Opening a tapped notification's request (#337): the sheet shows at once,
/// the named record is fetched first, and only a request the app verified
/// becomes the card.
@MainActor
final class OpenedRequestTests: XCTestCase {
    private var world: TestWorld!

    override func setUp() async throws {
        world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        await world.approveMac()
        await world.model.processInbox()
    }

    override func tearDown() async throws {
        world.cloud.callHook = nil
        world = nil
    }

    private func tap(_ name: String, on model: AppModel? = nil) async throws {
        let model = model ?? world.model
        await model.receivedPush(userInfo: TestWorld.alertPush(for: try world.phone.deviceID, record: name),
                                 arrivedAt: world.clock.now(), notificationIdentifier: "tapped", opened: true)
    }

    /// The phone's fetches, zone polls and fetches by name, in order.
    private func phoneFetches() throws -> [FakeCloud.Call.Kind] {
        try world.cloud.calls(by: world.phone.deviceID).filter {
            switch $0 {
            case .zoneFetch, .namedFetch: return true
            default: return false
            }
        }
    }

    /// Records, before each of the phone's transport calls, what the sheet showed.
    private func traceSheet(of model: AppModel, name: String) throws -> Box<[(FakeCloud.Call.Kind, String)]> {
        let trace = Box<[(FakeCloud.Call.Kind, String)]>([])
        let phone = try world.phone.deviceID.text
        world.cloud.callHook = { call in
            guard call.device == phone else { return }
            let shown = await MainActor.run { () -> String in
                guard model.openedRequest?.id == name else { return "nothing" }
                if let card = model.requests.first(where: { $0.id == name }) { return card.isChecking ? "checking" : "card" }
                return model.opening.map { "\($0.phase(at: Date.distantPast))" } ?? "gone"
            }
            trace.value.append((call.kind, shown))
        }
        return trace
    }

    // MARK: The named record first

    func testOpeningANotificationThatLaunchesTheAppFetchesItsRecordFirst() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        let launched = AppModel(environment: world.environment)
        world.cloud.clearCalls()
        let trace = try traceSheet(of: launched, name: name)

        try await tap(name, on: launched)
        await launched.start()
        XCTAssertEqual(launched.openedRequest, OpenedRequest(id: name), "the sheet opens before any fetch")
        XCTAssertEqual(launched.opening?.phase(at: world.clock.now()), .loading)
        await launched.becameActive()

        let phone = try world.phone.deviceID
        let calls = world.cloud.calls(by: phone)
        XCTAssertEqual(Array(calls.prefix(2)), [.accountState, .namedFetch([name])],
                       "only the account check comes before the record's own fetch")
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: .namedFetch([name]))),
                          try XCTUnwrap(calls.firstIndex(of: .prepareInbox)), "the inbox is prepared afterwards")
        XCTAssertEqual(try phoneFetches().first, .namedFetch([name]))
        let afterFetch = trace.value.drop { $0.0 != .namedFetch([name]) }.dropFirst()
        XCTAssertEqual(afterFetch.first?.1, "checking", "the card shows after that one fetch")
        XCTAssertEqual(trace.value.first { $0.0 == .zoneFetch }?.1, "checking", "undecidable until the zone poll ran")
        XCTAssertEqual(trace.value.first { $0.0 == .namedFetch([name]) }?.1, "loading")
        XCTAssertEqual(launched.openedRequest, OpenedRequest(id: name))
        XCTAssertEqual(launched.requests.map(\.id), [name])
        XCTAssertEqual(launched.requests.first?.isChecking, false, "decidable once the zone poll ran")
        XCTAssertNil(launched.opening)
        XCTAssertEqual(world.cloud.sent(.approvalReceipt, from: phone).count, 1)
    }

    func testATapThatArrivesWhileTheFirstPassChecksTheAccountIsFetchedRightAfterIt() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        let launched = AppModel(environment: world.environment)
        await launched.start()
        world.cloud.clearCalls()
        let gate = Gate()
        world.cloud.callHook = { call in
            if call.device == phone.text, call.kind == .accountState { await gate.wait() }
        }
        let active = Task { await launched.becameActive() }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.accountState) }
        let tapped = Task { try await self.tap(name, on: launched) }
        await waitUntil { launched.openedRequest != nil }
        XCTAssertEqual(launched.opening?.phase(at: world.clock.now()), .loading)
        gate.open()
        await active.value
        try await tapped.value
        let calls = world.cloud.calls(by: phone)
        XCTAssertEqual(Array(calls.prefix(2)), [.accountState, .namedFetch([name])])
        XCTAssertEqual(launched.requests.map(\.id), [name])
        XCTAssertEqual(launched.openedRequest, OpenedRequest(id: name))
    }

    func testTappingWhileTheAppRunsFetchesTheRecordBeforeTheZonePoll() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.clearCalls()
        let trace = try traceSheet(of: world.model, name: name)
        try await tap(name)
        XCTAssertEqual(try phoneFetches(), [.namedFetch([name]), .zoneFetch], "fetched by name once, never again")
        XCTAssertEqual(trace.value.first?.0, .namedFetch([name]))
        XCTAssertEqual(trace.value.first?.1, "loading")
        XCTAssertEqual(trace.value.dropFirst().first?.1, "checking")
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(world.model.opening)
        XCTAssertEqual(world.card?.isChecking, false)
    }

    func testATapWhileAPassWaitsForItsZonePollIsFetchedAlongsideIt() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        let gate = Gate()
        world.cloud.callHook = { call in
            if call.device == phone.text, call.kind == .zoneFetch { await gate.wait() }
        }
        let model = world.model
        world.cloud.clearCalls()
        let pass = Task { await model.processInbox() }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.zoneFetch) }
        let tapped = Task { try await self.tap(name) }
        await waitUntil { model.requests.contains { $0.id == name } }
        XCTAssertFalse(gate.isOpen, "the card showed while the zone poll was still waiting")
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name))
        XCTAssertEqual(model.card(name)?.isChecking, true, "that zone poll started before the fetch")
        gate.open()
        await pass.value
        try await tapped.value
        XCTAssertEqual(model.card(name)?.isChecking, false, "the next pass's zone poll checked it")
        XCTAssertEqual(world.cloud.sent(.approvalReceipt, from: phone).count, 1)
    }

    func testARecordBothTheTappedFetchAndAZonePollHoldTakesEffectOnce() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        let gate = Gate()
        let armed = Box(true)
        world.cloud.callHook = { call in
            guard call.device == phone.text, call.kind == .delete([name]), armed.value else { return }
            armed.value = false
            await gate.wait()
        }
        let model = world.model
        let tapped = Task { try await self.tap(name) }
        await waitUntil { !armed.value }
        // The tapped fetch handled the record and waits to delete it; a
        // zone poll now finds the same record.
        await model.processInbox()
        gate.open()
        try await tapped.value
        XCTAssertEqual(model.requests.map(\.id), [name])
        XCTAssertEqual(world.approvalStore.stored.requests.map(\.recordName), [name])
        XCTAssertEqual(world.cloud.sent(.approvalReceipt, from: phone).count, 1)
        XCTAssertTrue(world.cloud.records(in: phone).isEmpty)
    }

    func testASecondTapWhileTheFirstFetchWaitsIsFetchedAtOnce() async throws {
        let phone = try world.phone.deviceID
        let first = try await world.sendRequest().sealed.messageID.text
        let second = try await world.sendRequest(launchTime: TestWorld.macLaunch).sealed.messageID.text
        let gate = Gate()
        world.cloud.callHook = { call in
            if call.device == phone.text, call.kind == .namedFetch([first]) { await gate.wait() }
        }
        let model = world.model
        let tappedFirst = Task { try await self.tap(first) }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.namedFetch([first])) }
        let tappedSecond = Task { try await self.tap(second) }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.namedFetch([second])) }
        XCTAssertFalse(gate.isOpen)
        await waitUntil { model.card(second) != nil }
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: second))
        gate.open()
        try await tappedFirst.value
        try await tappedSecond.value
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: second), "the first fetch does not take the sheet back")
        XCTAssertEqual(Set(model.requests.map(\.id)), [first, second])
    }

    func testARequestTheAppAlreadyHoldsOpensWithoutAFetch() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        await world.model.processInbox()
        world.cloud.clearCalls()
        try await tap(name)
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(world.model.opening)
        XCTAssertFalse(try phoneFetches().contains(.namedFetch([name])))
    }

    func testTheExtensionsRecordNameOpensTheRequestToo() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        await world.model.receivedPush(userInfo: [PushHintReader.extensionRecordNameKey: name],
                                       arrivedAt: world.clock.now(), notificationIdentifier: "detailed", opened: true)
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
        XCTAssertEqual(world.model.requests.map(\.id), [name])
    }

    // MARK: Retry-after and failures

    func testRetryAfterHoldsTheNamedFetchAndTheSheetKeepsLoading() async throws {
        let phone = try world.phone.deviceID
        world.cloud.namedFetchRetryAfter = 30
        world.notifications.delivered = [PushHint(recordName: MessageID.random().text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "older")]
        await world.model.becameActive()
        world.cloud.namedFetchRetryAfter = nil
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.zoneFetchesFail = true
        world.cloud.clearCalls()

        try await tap(name)
        XCTAssertFalse(try phoneFetches().contains(.namedFetch([name])), "CloudKit asked to wait")
        XCTAssertEqual(world.model.opening?.phase(at: world.clock.now()), .loading)
        XCTAssertEqual(world.model.foregroundPollInterval, 2, "polls every 2 seconds while it loads")

        world.clock.advance(by: 31)
        await world.model.processInbox()
        XCTAssertTrue(try phoneFetches().contains(.namedFetch([name])))
        XCTAssertEqual(world.model.requests.map(\.id), [name])
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
        XCTAssertTrue(world.cloud.records(in: phone).isEmpty)
    }

    func testARetryAfterTheTappedFetchGetsDelaysItWithoutGivingItUp() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .rateLimited(retryAfter: 20)
        world.cloud.zoneFetchesFail = true
        try await tap(name)
        XCTAssertEqual(world.model.openingPhase(at: world.clock.now()), .loading, "asking to wait is no answer")
        world.cloud.namedFetchError = nil
        world.cloud.clearCalls()
        world.notifications.delivered = [PushHint(recordName: MessageID.random().text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "newer")]
        await world.model.becameActive()
        XCTAssertTrue(try phoneFetches().allSatisfy { if case .namedFetch = $0 { false } else { true } },
                      "no fetch by name during the retry-after")
        world.clock.advance(by: 21)
        await world.model.processInbox()
        XCTAssertEqual(try phoneFetches().first { if case .namedFetch = $0 { true } else { false } }, .namedFetch([name]),
                       "the tapped record still goes first")
        XCTAssertEqual(world.model.requests.map(\.id), [name])
        XCTAssertNil(world.model.opening)
    }

    func testLoadingEndsAfterAMinuteAndALaterCardStillShows() async throws {
        world.cloud.namedFetchRetryAfter = 90
        world.notifications.delivered = [PushHint(recordName: MessageID.random().text, arrivedAt: world.clock.now(),
                                                  notificationIdentifier: "older")]
        await world.model.becameActive()
        world.cloud.namedFetchRetryAfter = nil
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.zoneFetchesFail = true
        try await tap(name)
        world.clock.advance(by: 61)
        XCTAssertEqual(world.model.openingPhase(at: world.clock.now()), .unavailable)
        XCTAssertEqual(world.model.foregroundPollInterval, 10)
        world.clock.advance(by: 30)
        await world.model.processInbox()
        XCTAssertEqual(world.model.requests.map(\.id), [name], "a later card still replaces the unavailable state")
        XCTAssertNil(world.model.opening)
    }

    func testWithoutICloudTheSheetSaysSoAndTheRecordIsStillFetchedFirstOnceItIsBack() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.accountState = .temporarilyUnavailable
        let launched = AppModel(environment: world.environment)
        try await tap(name, on: launched)
        await launched.start()
        await launched.becameActive()
        XCTAssertEqual(launched.openingPhase(at: world.clock.now()), .unavailable)
        world.cloud.accountState = .available(userRecordName: "_user-a")
        world.cloud.clearCalls()
        await launched.processInbox()
        XCTAssertEqual(Array(world.cloud.calls(by: phone).prefix(2)), [.accountState, .namedFetch([name])])
        XCTAssertEqual(launched.requests.map(\.id), [name])
        XCTAssertNil(launched.openingPhase(at: world.clock.now()))
    }

    func testAFailedFetchByNameLeavesTheZonePollToFindIt() async throws {
        let name = try await world.sendRequest().sealed.messageID.text
        world.cloud.namedFetchError = .networkUnavailable
        try await tap(name)
        XCTAssertEqual(world.model.requests.map(\.id), [name])
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: name))
        XCTAssertNil(world.model.opening)
    }

    func testLoadingEndsAfterAMinute() {
        let tapped = Date(timeIntervalSince1970: 1_800_000_000)
        let opening = OpeningRequest(id: "record", since: tapped, step: .fetching)
        XCTAssertEqual(opening.phase(at: tapped.addingTimeInterval(59)), .loading)
        XCTAssertEqual(opening.phase(at: tapped.addingTimeInterval(60)), .unavailable)
    }

    // MARK: What can become a card

    func testANotificationNamingNoRecordShowsUnavailableAndNothingElse() async throws {
        let forged = MessageID.random().text
        await world.model.receivedPush(userInfo: [PushHintReader.extensionRecordNameKey: forged],
                                       arrivedAt: world.clock.now(), notificationIdentifier: "forged", opened: true)
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: forged))
        XCTAssertEqual(world.model.opening?.phase(at: world.clock.now()), .unavailable)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
    }

    func testANameThatIsNotAMessageIDOpensNothing() async throws {
        await world.model.receivedPush(userInfo: [PushHintReader.extensionRecordNameKey: "Codex wants GitHub Token"],
                                       arrivedAt: world.clock.now(), notificationIdentifier: "forged", opened: true)
        XCTAssertNil(world.model.openedRequest)
        XCTAssertNil(world.model.opening)
    }

    func testARequestFromAMacWithoutTheApprovalFlagShowsUnavailable() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        // Pairing sets the flag (#336); this is a Mac paired before it without approval.
        try await world.storeWithoutApprovalFlag(other)
        let name = try await world.sendRequest(from: other).sealed.messageID.text
        try await tap(name)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertEqual(world.model.opening?.phase(at: world.clock.now()), .unavailable)
        XCTAssertTrue(world.cloud.records(in: try world.phone.deviceID).isEmpty, "refused and deleted")
    }

    func testARequestFromAMacWhoseApprovalWasStoppedShowsUnavailable() async throws {
        let sealed = try await world.sealRequest()
        let stopped = await world.model.stopApproving(macID: world.macIdentity.deviceID.text)
        XCTAssertTrue(stopped)
        try await world.deliver(sealed.sealed.envelope)
        try await tap(sealed.sealed.messageID.text)
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertEqual(world.model.opening?.phase(at: world.clock.now()), .unavailable)
    }

    func testStopApprovingDuringTheFetchKeepsTheRequestFromBecomingACard() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        let gate = Gate()
        world.cloud.callHook = { call in
            if call.device == phone.text, call.kind == .namedFetch([name]) { await gate.wait() }
        }
        let model = world.model
        let tapped = Task { try await self.tap(name) }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.namedFetch([name])) }
        let stopped = await model.stopApproving(macID: world.macIdentity.deviceID.text)
        XCTAssertTrue(stopped)
        gate.open()
        try await tapped.value
        XCTAssertTrue(model.requests.isEmpty)
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertEqual(model.openingPhase(at: world.clock.now()), .unavailable)
    }

    func testAnAccountChangeDuringTheFetchKeepsTheRequestFromBecomingACard() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.sendRequest().sealed.messageID.text
        let model = world.model
        let cloud = world.cloud
        world.cloud.callHook = { call in
            guard call.device == phone.text, call.kind == .namedFetch([name]) else { return }
            cloud.accountState = .available(userRecordName: "_user-b")
            await model.refreshAccount()
        }
        model.open(name)
        await model.fetchOpenedRecord(try XCTUnwrap(model.services))
        XCTAssertTrue(model.requests.isEmpty, "the old messenger's request is not accepted")
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty)
        XCTAssertEqual(world.cloud.records(in: phone).map(\.recordName), [name], "it stays in the inbox")
        XCTAssertEqual(model.opening?.phase(at: world.clock.now()), .loading, "due again for the next pass")
    }

    func testATappedRequestWhoseClosedMessageWaitsInTheZoneIsNeverDecidable() async throws {
        let phone = try world.phone.deviceID
        let sealed = try await world.sealRequest()
        let name = sealed.sealed.messageID.text
        try await world.deliver(sealed.sealed.envelope)
        try await world.sendClosed(.decidedOnMac, for: sealed)
        let model = world.model
        let decidable = Box(false)
        world.cloud.callHook = { call in
            guard call.device == phone.text else { return }
            await MainActor.run {
                if let card = model.card(name), !card.isChecking, card.phase(at: Date.distantPast) == .pending {
                    decidable.value = true
                }
            }
            // Deny needs no Face ID: try it while the card shows.
            await model.decide(.deny, requestID: name)
        }
        try await tap(name)
        XCTAssertFalse(decidable.value, "never a pending card that can be decided")
        let card = try XCTUnwrap(model.card(name))
        XCTAssertEqual(card.phase(at: world.clock.now()), .closed(.decidedOnMac), "the zone poll right after closes it")
        XCTAssertTrue(try world.decisionAttempts().isEmpty)
        XCTAssertTrue(world.cloud.sent(.approvalReceipt, from: phone).isEmpty, "no receipt for a closed request")
    }

    func testATappedDeliveryCheckClosesTheSheet() async throws {
        let name = try await world.mac.sendDeliveryCheck(to: try world.phone.deviceID).text
        try await tap(name)
        XCTAssertNil(world.model.openedRequest, "not a request")
        XCTAssertNil(world.model.opening)
        XCTAssertEqual(world.model.deliveryRecords.last?.recordName, name)
    }

    /// The tapped fetch handles the delivery check while a zone poll finds it busy.
    func testATappedDeliveryCheckTheTappedFetchWinsClosesTheSheet() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.mac.sendDeliveryCheck(to: phone).text
        let (gate, armed) = holdFirstSend(of: .deliveryCheckReply, by: phone)
        let model = world.model
        let tapped = Task { try await self.tap(name) }
        await waitUntil { !armed.value }
        await model.processInbox()
        XCTAssertEqual(model.openedRequest, OpenedRequest(id: name), "still handled by the tapped fetch")
        gate.open()
        try await tapped.value
        XCTAssertNil(model.openedRequest)
        XCTAssertNil(model.opening)
        XCTAssertEqual(model.deliveryRecords.filter { $0.recordName == name }.count, 1)
    }

    /// A zone poll handles the delivery check while the tapped fetch finds it busy.
    func testATappedDeliveryCheckAZonePollWinsClosesTheSheet() async throws {
        let phone = try world.phone.deviceID
        let name = try await world.mac.sendDeliveryCheck(to: phone).text
        let (gate, armed) = holdFirstSend(of: .deliveryCheckReply, by: phone)
        let model = world.model
        let pass = Task { await model.processInbox() }
        await waitUntil { !armed.value }
        let tapped = Task { try await self.tap(name) }
        await waitUntil { self.world.cloud.calls(by: phone).contains(.namedFetch([name])) && model.opening?.step == .fetchDue }
        gate.open()
        await pass.value
        try await tapped.value
        XCTAssertNil(model.openedRequest)
        XCTAssertNil(model.opening)
        XCTAssertEqual(model.deliveryRecords.filter { $0.recordName == name }.count, 1)
    }

    // MARK: Helpers

    /// Holds the first send of `kind` by `device` until the gate opens.
    private func holdFirstSend(of kind: MessageKind, by device: DeviceID) -> (Gate, Box<Bool>) {
        let gate = Gate()
        let armed = Box(true)
        world.cloud.callHook = { call in
            guard call.device == device.text, call.kind == .send(Int64(kind.rawValue)), armed.value else { return }
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
}

extension AppModel {
    func card(_ id: String) -> RequestCard? { requests.first { $0.id == id } }
}

/// Holds a caller until the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool { lock.withLock { opened } }

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
