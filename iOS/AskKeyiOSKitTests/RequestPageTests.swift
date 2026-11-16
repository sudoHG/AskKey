import AskKeyDevices
import SwiftUI
import XCTest
@testable import AskKeyiOSKit

/// The request page (#347): the buttons' order and progress, the outcome
/// pages' symbols and colors, and the archive rule (decision 7 of #344).
@MainActor
final class RequestPageTests: XCTestCase {
    private var world: TestWorld!

    override func tearDown() async throws {
        world = nil
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func card(offers: ApprovalOffers = .all, decision: ApprovalDecisionCode? = nil, isSent: Bool = false,
                             outcome: RequestOutcome? = nil, isGone: Bool = false,
                             secondsLeft: TimeInterval = 200) -> RequestCard {
        let display = RequestDisplay(requesterName: "Codex", purpose: "", credentialName: "GitHub Token",
                                     commandLine: "./deploy.sh", workingDirectory: "", executableName: "deploy.sh",
                                     deliveryRows: [], offers: offers, timedDuration: offers == .all ? 1_800 : 0)
        return RequestCard(id: "request", macID: "mac", macName: TestWorld.macName, macPairedAt: now, display: display,
                           countdownEnd: now.addingTimeInterval(secondsLeft), decision: decision, isSent: isSent,
                           outcome: outcome, isGone: isGone)
    }

    private static let endings: [RequestEnding] = [
        .closed(.allowedOnce), .closed(.allowedTimed(seconds: 1_800)), .closed(.denied), .closed(.decidedOnMac),
        .closed(.decidedElsewhere), .closed(.expired), .closed(.cancelled), .closed(.notApplied), .timedOut, .gone,
    ]

    // MARK: Buttons

    /// The Mac card's order: Allow Once, the timed allowance, Deny.
    func testThePageOrdersTheButtonsAsTheMacCardDoes() {
        XCTAssertEqual(Self.card(offers: .all).pageButtons(at: Self.now), [.allowOnce, .timedAllowance, .deny])
        XCTAssertEqual(Self.card(offers: .denyOrAllowOnce).pageButtons(at: Self.now), [.allowOnce, .deny])
        XCTAssertEqual(Self.card(offers: .denyOnly).pageButtons(at: Self.now), [.deny])
    }

    /// Sending and waiting keep only the chosen button; a finished request has none.
    func testOnlyTheChosenButtonStaysOnceADecisionIsStored() {
        XCTAssertEqual(Self.card(decision: .deny).pageButtons(at: Self.now), [.deny])
        XCTAssertEqual(Self.card(decision: .timedAllowance, isSent: true).pageButtons(at: Self.now), [.timedAllowance])
        XCTAssertEqual(Self.card(decision: .allowOnce, isSent: true, outcome: .allowedOnce).pageButtons(at: Self.now), [])
        XCTAssertEqual(Self.card(secondsLeft: 0).pageButtons(at: Self.now), [])
        XCTAssertEqual(Self.card(isGone: true).pageButtons(at: Self.now), [])
    }

    func testADenyOnlyRequestSaysWhy() {
        XCTAssertNil(RequestActions.denyOnlyNote(Self.card(offers: .denyOrAllowOnce).display))
        XCTAssertEqual(RequestActions.denyOnlyNote(Self.card(offers: .denyOnly).display),
                       LocalizedStringKey("request.denyOnly.shortened"))
        let refused = RequestDisplay(requesterName: "", purpose: "", credentialName: "NAS Admin", commandLine: "ssh nas",
                                     workingDirectory: "", executableName: "ssh", deliveryRows: [],
                                     deliveryMetadataUnavailable: true, offers: .denyOnly)
        XCTAssertEqual(RequestActions.denyOnlyNote(refused), LocalizedStringKey("request.handsOver.unavailable"),
                       "the run will be refused, so the Mac cannot allow it either")
    }

    // MARK: Outcome pages

    /// Decision 3 of #344: allowed is green, denied red, and no outcome
    /// shares a tone, or a color, between the two.
    func testNoOutcomeSharesAToneBetweenAllowedAndDenied() {
        let allowed = Self.endings.filter {
            if case .closed(.allowedOnce) = $0 { return true }
            if case .closed(.allowedTimed) = $0 { return true }
            return false
        }
        let denied = Self.endings.filter { $0 == .closed(.denied) }
        XCTAssertEqual(Set(allowed.map(\.tone)), [.allowed])
        XCTAssertEqual(Set(denied.map(\.tone)), [.denied])
        for ending in Self.endings where !allowed.contains(ending) && !denied.contains(ending) {
            XCTAssertFalse([EndingTone.allowed, .denied].contains(ending.tone), "\(ending) looks allowed or denied")
        }
        XCTAssertTrue(Set(allowed.map(\.symbol)).isDisjoint(with: denied.map(\.symbol)))
        XCTAssertEqual(Set(EndingTone.allCases.map(\.color)).count, EndingTone.allCases.count, "every tone has its own color")
        XCTAssertEqual(EndingTone.allowed.color, .green)
        XCTAssertEqual(EndingTone.denied.color, .red)
    }

    /// #347's outcome table: each ending's symbol and color.
    func testEveryEndingHasTheSymbolAndToneOfTheTable() {
        let expected: [(RequestEnding, String, EndingTone)] = [
            (.closed(.allowedOnce), "checkmark.circle.fill", .allowed),
            (.closed(.allowedTimed(seconds: 1_800)), "checkmark.circle.fill", .allowed),
            (.closed(.denied), "xmark.circle.fill", .denied),
            (.closed(.decidedOnMac), "desktopcomputer", .neutral),
            (.closed(.decidedElsewhere), "iphone", .neutral),
            (.closed(.expired), "clock.fill", .neutral),
            (.closed(.cancelled), "minus.circle.fill", .neutral),
            (.timedOut, "exclamationmark.circle.fill", .attention),
            (.gone, "exclamationmark.circle.fill", .attention),
            (.closed(.notApplied), "exclamationmark.circle.fill", .attention),
        ]
        XCTAssertEqual(expected.count, Self.endings.count)
        for (ending, symbol, tone) in expected {
            XCTAssertEqual(ending.symbol, symbol, "\(ending)")
            XCTAssertEqual(ending.tone, tone, "\(ending)")
        }
    }

    func testOnlyAFinishedRequestHasAnOutcomePage() {
        XCTAssertNil(Self.card().phase(at: Self.now).ending)
        XCTAssertNil(Self.card(decision: .deny).phase(at: Self.now).ending)
        XCTAssertNil(Self.card(decision: .deny, isSent: true).phase(at: Self.now).ending)
        XCTAssertEqual(Self.card(decision: .deny, isSent: true, outcome: .denied).phase(at: Self.now).ending,
                       .closed(.denied))
        XCTAssertEqual(Self.card(decision: .deny, secondsLeft: 0).phase(at: Self.now).ending, .timedOut)
        XCTAssertEqual(Self.card(isGone: true).phase(at: Self.now).ending, .gone)
    }

    // MARK: Archive rule

    private func pairedWorld() async throws -> TestWorld {
        let world = TestWorld()
        await world.setUpPhone()
        try await world.pair()
        self.world = world
        return world
    }

    /// A closed message for a request the iPhone has not fetched yet leaves
    /// a marker, so the archive checks below see one in the stored state.
    private func storeMarker(in world: TestWorld) async throws {
        let unseen = try await world.sealRequest()
        try await world.sendClosed(.decidedOnMac, for: unseen)
        await world.model.processInbox()
        XCTAssertEqual(world.approvalStore.stored.markers.count, 1)
    }

    /// Settled while its page is open: the page keeps the outcome until the
    /// person closes it, the Requests tab no longer lists the request, and
    /// closing the page changes nothing stored.
    func testARequestSettledWhileItsPageIsOpenKeepsItsOutcomePageUntilClosed() async throws {
        let world = try await pairedWorld()
        try await storeMarker(in: world)
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        let id = sealed.sealed.messageID.text
        world.model.open(id)
        await world.model.decide(.deny, requestID: id)
        try await world.sendClosed(.applied, code: .deny, for: sealed)
        await world.model.processInbox()

        let now = world.clock.now()
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: id), "the page stays open")
        let card = try XCTUnwrap(world.model.requests.first { $0.id == id })
        XCTAssertEqual(card.phase(at: now).ending, .closed(.denied), "and shows the outcome")
        XCTAssertFalse(world.model.activeRequests(at: now).contains { $0.id == id })
        let stored = world.approvalStore.stored
        let attempts = try world.decisionAttempts().count

        world.model.openedRequest = nil
        await world.model.processInbox()
        XCTAssertFalse(world.model.activeRequests(at: world.clock.now()).contains { $0.id == id })
        XCTAssertEqual(world.approvalStore.stored, stored, "the request, its decision and the marker are unchanged")
        XCTAssertEqual(world.approvalStore.stored.requests.first { $0.recordName == id }?.dismissed, false)
        XCTAssertEqual(try world.decisionAttempts().count, attempts, "closing the page sends nothing")
    }

    /// The countdown's end settles an open page too: it shows Time Ran Out
    /// until it is closed.
    func testACountdownThatEndsWhileThePageIsOpenKeepsThePage() async throws {
        let world = try await pairedWorld()
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        let id = sealed.sealed.messageID.text
        world.model.open(id)
        await world.model.decide(.deny, requestID: id)
        world.clock.advance(by: 300)
        await world.model.processInbox()
        let now = world.clock.now()
        XCTAssertEqual(world.model.openedRequest, OpenedRequest(id: id))
        XCTAssertEqual(world.model.requests.first { $0.id == id }?.phase(at: now).ending, .timedOut)
        XCTAssertTrue(world.model.activeRequests(at: now).isEmpty)
    }

    /// Settled while its page is closed: it leaves the Requests tab at once,
    /// and its stored request stays as ADR 0014 keeps it.
    func testARequestSettledWhileItsPageIsClosedLeavesTheRequestsTabAtOnce() async throws {
        let world = try await pairedWorld()
        try await storeMarker(in: world)
        let sealed = try await world.sendRequest()
        await world.model.processInbox()
        let id = sealed.sealed.messageID.text
        XCTAssertEqual(world.model.activeRequests(at: world.clock.now()).map(\.id), [id])
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()

        XCTAssertNil(world.model.openedRequest)
        XCTAssertTrue(world.model.activeRequests(at: world.clock.now()).isEmpty)
        let entry = try XCTUnwrap(world.approvalStore.stored.requests.first { $0.recordName == id })
        XCTAssertNotNil(entry.closed, "the closed outcome is stored")
        XCTAssertFalse(entry.dismissed)
        XCTAssertEqual(world.approvalStore.stored.markers.count, 1, "the marker is unchanged")
    }
}
