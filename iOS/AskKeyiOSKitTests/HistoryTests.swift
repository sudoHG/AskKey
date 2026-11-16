import AskKeyDevices
import XCTest
@testable import AskKeyiOSKit

/// The history's entries (#349, ADR 0014 → iPhone app → History, amended by
/// #345): one per verified request, captured at verification and completed
/// when the request ends.
@MainActor
final class HistoryTests: XCTestCase {
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

    private func receive(_ peer: MacPeer? = nil, lifetime: TimeInterval = 300, launchTime: Date = TestWorld.macLaunch,
                         offers: ApprovalOffers = .denyOrAllowOnce,
                         timedDuration: UInt64 = 0) async throws -> SealedApprovalRequest {
        let sealed = try await world.sendRequest(from: peer, lifetime: lifetime, launchTime: launchTime, offers: offers,
                                                 timedDuration: timedDuration)
        await world.model.processInbox()
        return sealed
    }

    private func entry(_ sealed: SealedApprovalRequest) -> HistoryEntry? {
        world.model.historyState.entries.first { $0.recordName == sealed.sealed.messageID.text }
    }

    // MARK: One entry per request

    func testAnAllowedRequestIsCapturedOpenAndCompletedOnceWithItsFields() async throws {
        let receivedAt = world.clock.now()
        let sealed = try await receive()
        let id = sealed.sealed.messageID.text
        XCTAssertTrue(world.model.history.isEmpty, "History does not show an open entry")
        XCTAssertEqual(world.model.historyState.entries.map(\.recordName), [id], "captured at verification")
        XCTAssertEqual(world.storedHistory?.entries.map(\.recordName), [id], "and written")

        world.clock.advance(by: 20)
        await world.model.decide(.allowOnce, requestID: id)
        try await world.sendClosed(.applied, code: .allowOnce, for: sealed)
        world.clock.advance(by: 5)
        await world.model.processInbox()

        let entry = try XCTUnwrap(world.model.history.first)
        XCTAssertEqual(world.model.history.count, 1)
        XCTAssertEqual(entry.recordName, id)
        XCTAssertEqual(entry.macID, macID)
        XCTAssertEqual(entry.macName, TestWorld.macName)
        XCTAssertEqual(entry.requesterName, "Codex")
        XCTAssertEqual(entry.credentialName, "GitHub Token")
        XCTAssertEqual(entry.executableName, "deploy.sh")
        XCTAssertEqual(entry.receivedAt, receivedAt)
        XCTAssertEqual(entry.endedAt, world.clock.now(), "when the app processed the closed message")
        XCTAssertEqual(entry.ending, .closed(.allowedOnce))
        XCTAssertEqual(entry.decisionCode, ApprovalDecisionCode.allowOnce.rawValue)
        XCTAssertEqual(world.storedHistory?.entries, world.model.historyState.entries)
        XCTAssertTrue(world.model.isSavedToHistory(try XCTUnwrap(world.card)), "the outcome page may say it was saved")
        XCTAssertTrue(world.model.decidingRequest == nil && !world.model.isAuthenticating)
    }

    func testEveryClosedOutcomeIsRecordedOnce() async throws {
        let timed = try await receive(offers: .all, timedDuration: 1_800)
        await world.model.decide(.timedAllowance, requestID: timed.sealed.messageID.text)
        try await world.sendClosed(.applied, code: .timedAllowance, duration: 1_800, for: timed)
        let denied = try await receive()
        await world.model.decide(.deny, requestID: denied.sealed.messageID.text)
        try await world.sendClosed(.applied, code: .deny, for: denied)
        var others: [(SealedApprovalRequest, RequestOutcome)] = []
        for (outcome, expected) in [(ApprovalClosedOutcome.decidedOnMac, RequestOutcome.decidedOnMac),
                                    (.decidedOnAnotherApprover, .decidedElsewhere), (.expired, .expired),
                                    (.cancelled, .cancelled), (.notApplied, .notApplied)] {
            let sealed = try await receive()
            try await world.sendClosed(outcome, for: sealed)
            others.append((sealed, expected))
        }
        await world.model.processInbox()
        await world.model.processInbox()

        XCTAssertEqual(entry(timed)?.ending, .closed(.allowedTimed(seconds: 1_800)))
        XCTAssertEqual(entry(denied)?.ending, .closed(.denied))
        for (sealed, expected) in others {
            XCTAssertEqual(entry(sealed)?.ending, .closed(expected))
        }
        XCTAssertEqual(world.model.history.count, 7)
        XCTAssertEqual(Set(world.model.history.map(\.id)).count, 7, "exactly one entry per request")
        XCTAssertEqual(world.storedHistory?.entries.filter(\.isCompleted).count, 7)
    }

    func testATimeoutEndsAtTheCountdownAndALateClosedMessageCorrectsItKeepingTheEndedTime() async throws {
        let sealed = try await receive()
        let countdownEnd = try XCTUnwrap(world.card?.countdownEnd)
        world.clock.advance(by: 310)
        await world.model.processInbox()
        XCTAssertEqual(entry(sealed)?.ending, .timedOut)
        XCTAssertEqual(entry(sealed)?.endedAt, countdownEnd, "the countdown's end, which is earlier")

        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.model.history.count, 1)
        XCTAssertEqual(entry(sealed)?.ending, .closed(.decidedOnMac))
        XCTAssertEqual(entry(sealed)?.endedAt, countdownEnd)
        XCTAssertEqual(world.storedHistory?.entries.first?.ending, .closed(.decidedOnMac))
    }

    func testALateClosedMessageAfterTheStoredRequestExpiredCorrectsTheEntryInsteadOfAMarker() async throws {
        let sealed = try await receive()
        await world.model.decide(.deny, requestID: sealed.sealed.messageID.text)
        world.clock.advance(by: 700)
        await world.model.processInbox()
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty, "past its transport expiry")
        XCTAssertEqual(entry(sealed)?.ending, .timedOut)

        // Outcome 1 counts only as the decision this iPhone sent.
        try await world.sendClosed(.applied, code: .allowOnce, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(entry(sealed)?.ending, .timedOut)
        try await world.sendClosed(.applied, code: .deny, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(entry(sealed)?.ending, .closed(.denied))
        XCTAssertTrue(world.approvalStore.stored.markers.isEmpty, "not kept as a marker")
        XCTAssertEqual(world.model.history.count, 1)
    }

    func testALaterLaunchTimeCompletesTheOlderRequestAsGone() async throws {
        let older = try await receive()
        world.clock.advance(by: 30)
        let newer = try await receive(launchTime: TestWorld.macLaunch.addingTimeInterval(60))
        XCTAssertEqual(entry(older)?.ending, .gone)
        XCTAssertEqual(entry(older)?.endedAt, world.clock.now())
        XCTAssertNil(entry(newer)?.endedAt, "the newer request is still open")
    }

    func testATimeoutBeforeALaterLaunchTimeStaysATimeout() async throws {
        let older = try await receive(lifetime: 30)
        let countdownEnd = try XCTUnwrap(world.card?.countdownEnd)
        world.clock.advance(by: 60)
        _ = try await receive(launchTime: TestWorld.macLaunch.addingTimeInterval(60))
        XCTAssertEqual(entry(older)?.ending, .timedOut, "the countdown ended first")
        XCTAssertEqual(entry(older)?.endedAt, countdownEnd)
    }

    func testRelaunchedAfterTheTransportExpiryGivesOneTimedOutEntry() async throws {
        let sealed = try await receive()
        let countdownEnd = try XCTUnwrap(world.card?.countdownEnd)
        world.clock.advance(by: 700)
        let relaunched = await world.relaunch()
        XCTAssertEqual(relaunched.history.count, 1)
        XCTAssertEqual(relaunched.history.first?.recordName, sealed.sealed.messageID.text)
        XCTAssertEqual(relaunched.history.first?.ending, .timedOut)
        XCTAssertEqual(relaunched.history.first?.endedAt, countdownEnd)
        XCTAssertEqual(world.storedHistory?.entries.filter(\.isCompleted).count, 1)
    }

    // MARK: Closed messages before their requests

    func testAClosedMessageAndItsRequestInOneFetchGiveOneEntryAndNoCard() async throws {
        let sealed = try await world.sealRequest()
        try await world.sendClosed(.decidedOnMac, for: sealed)
        try await world.deliver(sealed.sealed.envelope)
        await world.model.processInbox()

        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertEqual(world.model.history.count, 1)
        let entry = try XCTUnwrap(world.model.history.first)
        XCTAssertEqual(entry.ending, .closed(.decidedOnMac))
        XCTAssertEqual(entry.receivedAt, world.clock.now())
        XCTAssertEqual(entry.endedAt, world.clock.now())
        XCTAssertEqual(world.approvalStore.stored.markers.count, 1, "the marker stays and keeps the request hidden")
        XCTAssertNil(world.approvalStore.stored.markers.first?.closed, "its outcome is used once")

        world.model.clearHistory()
        try await world.deliver(sealed.sealed.envelope)
        await world.model.processInbox()
        XCTAssertTrue(world.model.history.isEmpty, "a cleared entry never comes back")
    }

    func testAMarkerWithOutcomeOneOrWithoutAnOutcomeGivesNoEntry() async throws {
        let applied = try await world.sealRequest()
        try await world.sendClosed(.applied, code: .allowOnce, for: applied)
        let older = try await world.sealRequest()
        try await world.sendClosed(.expired, for: older)
        await world.model.processInbox()
        XCTAssertEqual(world.approvalStore.stored.markers.count, 2)
        // As a file from before #349 stores it.
        var state = world.model.approvals
        let index = try XCTUnwrap(state.markers.firstIndex { $0.requestDigest == older.requestDigest })
        state.markers[index].closed = nil
        world.model.commitApprovals(state)

        try await world.deliver(applied.sealed.envelope)
        try await world.deliver(older.sealed.envelope)
        await world.model.processInbox()
        XCTAssertTrue(world.model.requests.isEmpty)
        XCTAssertTrue(world.model.historyState.entries.isEmpty)
    }

    func testAReusedRecordNameFromAnotherMacLeavesTheFirstEntryUnchanged() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        let sealed = try await world.sealRequest(from: other)
        let name = sealed.sealed.messageID.text
        // The primary Mac's earlier request had the same record name and timed out.
        let first = TestWorld.historyEntry(mac: macID, recordName: name, endedAt: world.clock.now().addingTimeInterval(-60))
        world.model.changeHistory { $0.entries.append(first) }

        try await world.deliver(sealed.sealed.envelope)
        await world.model.processInbox()
        try await world.sendClosed(.expired, for: sealed, from: other)
        await world.model.processInbox()

        XCTAssertEqual(world.model.history.count, 2)
        XCTAssertEqual(world.model.historyState.entries.first { $0.id == first.id }, first, "unchanged")
        let second = try XCTUnwrap(world.model.history.first { $0.macID == other.deviceID.text })
        XCTAssertEqual(second.recordName, name)
        XCTAssertEqual(second.macName, "Office Mac")
        XCTAssertEqual(second.ending, .closed(.expired))
    }

    // MARK: Removal and clearing

    func testARemovedMacKeepsTheEntriesOfEndedRequestsAndDropsOpenOnes() async throws {
        let ended = try await world.sendRequest(lifetime: 30)
        let pending = try await world.sendRequest()
        await world.model.processInbox()
        world.clock.advance(by: 60)
        XCTAssertNil(entry(ended)?.endedAt, "not completed until something looks")

        let removed = await world.model.removeMac(id: macID)
        XCTAssertTrue(removed)
        XCTAssertEqual(world.model.history.map(\.recordName), [ended.sealed.messageID.text])
        XCTAssertEqual(world.model.history.first?.ending, .timedOut)
        XCTAssertNil(entry(pending), "a request dropped before it ended gets none")
        XCTAssertEqual(world.storedHistory?.entries.map(\.recordName), [ended.sealed.messageID.text])
        XCTAssertEqual(world.model.historyCount(forMac: macID), 1, "History for This Mac still lists it")
    }

    func testAnUnpairNoticeKeepsEndedEntriesAndDropsOpenOnes() async throws {
        let ended = try await world.sendRequest(lifetime: 30)
        let pending = try await world.sendRequest()
        await world.model.processInbox()
        world.clock.advance(by: 60)
        try await world.mac.removeDevice(try world.phone.deviceID)
        await world.model.processInbox()
        XCTAssertTrue(world.model.pairedMacs.isEmpty)
        XCTAssertEqual(world.model.history.map(\.recordName), [ended.sealed.messageID.text])
        XCTAssertEqual(world.model.history.first?.ending, .timedOut)
        XCTAssertNil(entry(pending))
    }

    func testALateClosedMessageAfterClearAllHistoryAddsNothing() async throws {
        let stored = try await receive()
        let expired = try await receive()
        world.clock.advance(by: 310)
        await world.model.processInbox()
        XCTAssertEqual(world.model.history.count, 2)
        world.model.clearHistory()
        world.clock.advance(by: 200)
        await world.model.processInbox()
        XCTAssertEqual(world.approvalStore.stored.requests.count, 2, "still stored")
        try await world.sendClosed(.decidedOnMac, for: stored)
        await world.model.processInbox()
        world.clock.advance(by: 200)
        await world.model.processInbox()
        XCTAssertTrue(world.approvalStore.stored.requests.isEmpty, "past the transport expiry")
        try await world.sendClosed(.expired, for: expired)
        await world.model.processInbox()
        XCTAssertTrue(world.model.historyState.entries.isEmpty, "a cleared entry never comes back")
        XCTAssertNil(world.historyFiles.storedData)
    }

    func testClearAllHistoryRemovesCompletedEntriesAndReplacesTheKey() async throws {
        let done = try await receive()
        try await world.sendClosed(.decidedOnMac, for: done)
        let open = try await receive()
        let oldKey = try XCTUnwrap(world.historyKeys.storedKey)
        XCTAssertEqual(world.model.history.count, 1)

        world.model.clearHistory()
        XCTAssertTrue(world.model.history.isEmpty)
        XCTAssertTrue(world.model.savedHistory.isEmpty)
        XCTAssertNotEqual(world.historyKeys.storedKey, oldKey, "the key is replaced")
        XCTAssertEqual(world.storedHistory?.entries.map(\.recordName), [open.sealed.messageID.text],
                       "a request in progress keeps its open entry")

        try await world.sendClosed(.expired, for: open)
        await world.model.processInbox()
        world.model.clearHistory()
        XCTAssertNil(world.historyFiles.storedData, "nothing left: the file goes")
        XCTAssertNil(world.historyKeys.storedKey)
        let relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
    }

    // MARK: Account and identity

    func testASignOutWithNoStoredRequestDeletesTheHistory() async throws {
        try world.storeHistory([TestWorld.historyEntry(endedAt: world.clock.now())])
        let relaunched = await world.relaunch()
        XCTAssertEqual(relaunched.history.count, 1)
        XCTAssertTrue(world.approvalStore.stored.isEmpty)

        world.cloud.accountState = .noAccount
        await relaunched.refreshAccount()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey)
    }

    func testAnAccountChangeARestrictionAndAnIdentityResetDeleteTheHistory() async throws {
        for state in [CloudKitAccountState.available(userRecordName: "_user-b"), .restricted] {
            let sealed = try await receive()
            try await world.sendClosed(.decidedOnMac, for: sealed)
            await world.model.processInbox()
            XCTAssertEqual(world.model.history.count, 1)
            world.cloud.accountState = state
            await world.model.refreshAccount()
            XCTAssertTrue(world.model.historyState.entries.isEmpty, "\(state)")
            XCTAssertNil(world.historyFiles.storedData, "\(state)")
            XCTAssertNil(world.historyKeys.storedKey, "\(state)")
            world.cloud.accountState = .available(userRecordName: "_user-b")
            await world.model.refreshAccount()
        }

        let sealed = try await receive()
        try await world.sendClosed(.expired, for: sealed)
        await world.model.processInbox()
        XCTAssertNotNil(world.historyFiles.storedData)
        world.identities.restoringError = .unusable
        let relaunched = await world.relaunch()
        XCTAssertEqual(relaunched.stage, .unusableIdentity)
        await relaunched.resetIdentity()
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey)
    }

    func testAFailedDeletionIsRetriedAtLaunchBeforeTheFileIsRead() async throws {
        let sealed = try await receive()
        try await world.sendClosed(.decidedOnMac, for: sealed)
        await world.model.processInbox()
        world.historyKeys.deletesFail = true
        world.historyFiles.removalsFail = true
        world.cloud.accountState = .noAccount
        await world.model.refreshAccount()
        XCTAssertTrue(world.model.history.isEmpty, "the entries in memory go at once")
        XCTAssertNotNil(world.historyFiles.storedData)
        XCTAssertNotNil(world.historyKeys.storedKey)
        XCTAssertTrue(world.historyFiles.isDeletionPending)

        let stillFailing = await world.relaunch()
        XCTAssertTrue(stillFailing.history.isEmpty, "never read while the deletion fails")
        world.historyKeys.deletesFail = false
        world.historyFiles.removalsFail = false
        let relaunched = await world.relaunch()
        XCTAssertTrue(relaunched.history.isEmpty)
        XCTAssertNil(world.historyFiles.storedData)
        XCTAssertNil(world.historyKeys.storedKey)
        XCTAssertFalse(world.historyFiles.isDeletionPending)
    }

    // MARK: Writes

    func testAFailedWriteNeverBlocksADecisionAndIsRetriedAtTheNextSave() async throws {
        world.historyFiles.writesFail = true
        let sealed = try await receive()
        let id = sealed.sealed.messageID.text
        await world.model.decide(.deny, requestID: id)
        XCTAssertEqual(try world.decisionAttempts().count, 1, "the decision went out")
        try await world.sendClosed(.applied, code: .deny, for: sealed)
        await world.model.processInbox()
        XCTAssertEqual(world.model.history.first?.ending, .closed(.denied), "kept in memory")
        XCTAssertFalse(world.model.isSavedToHistory(try XCTUnwrap(world.card)), "not said to be saved")
        XCTAssertNil(world.historyFiles.storedData)

        world.historyFiles.writesFail = false
        await world.model.processInbox()
        XCTAssertEqual(world.storedHistory?.entries.first?.ending, .closed(.denied))
        XCTAssertTrue(world.model.isSavedToHistory(try XCTUnwrap(world.card)))
    }

    func testEntriesCapturedWhileTheFileCannotBeReadAreAddedToIt() async throws {
        let earlier = TestWorld.historyEntry(endedAt: world.clock.now().addingTimeInterval(-3_600))
        try world.storeHistory([earlier])
        world.historyFiles.readsFail = true
        let relaunched = await world.relaunch()
        let sealed = try await world.sendRequest()
        await relaunched.processInbox()
        XCTAssertEqual(world.storedHistory?.entries, [earlier], "nothing is written over a file it could not read")

        world.historyFiles.readsFail = false
        await relaunched.processInbox()
        XCTAssertEqual(Set(world.storedHistory?.entries.map(\.recordName) ?? []),
                       [earlier.recordName, sealed.sealed.messageID.text])
    }

    // MARK: Showing

    func testHistoryForThisMacFiltersByDeviceIDWithoutAPrompt() async throws {
        let other = world.makeMac(name: "Office Mac")
        try await world.pair(other)
        let mine = try await receive()
        try await world.sendClosed(.expired, for: mine)
        let theirs = try await receive(other)
        try await world.sendClosed(.expired, for: theirs, from: other)
        await world.model.processInbox()
        let prompts = try world.phone.approvalReasons.count

        world.model.historyDetail = mine.sealed.messageID.text
        world.model.showHistory(forMac: other.deviceID.text, name: "Office Mac")
        XCTAssertEqual(world.model.selectedTab, .history)
        XCTAssertEqual(world.model.historyFilter, HistoryFilter(macID: other.deviceID.text, macName: "Office Mac"))
        XCTAssertNil(world.model.historyDetail, "the list shows, not an entry left open")
        XCTAssertEqual(world.model.historyCount(forMac: other.deviceID.text), 1)
        XCTAssertEqual(world.model.historyCount(forMac: macID), 1)
        XCTAssertEqual(try world.phone.approvalReasons.count, prompts, "History asks for no Face ID")
        XCTAssertFalse(world.model.isAuthenticating)
    }

    func testDaysAreTodayYesterdayThenOlderNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = world.clock.now()
        let entries = [0.0, -600, -86_400, -3 * 86_400].map { TestWorld.historyEntry(endedAt: now.addingTimeInterval($0)) }
        let sections = HistoryDays.sections(entries, calendar: calendar)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections.map(\.entries.count), [2, 1, 1])
        XCTAssertEqual(sections.first?.day, calendar.startOfDay(for: now))
    }
}
