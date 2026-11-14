import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Verifying and applying a decision, and how every approver learns how a
/// request ended (ADR 0014 → Verifying and applying a decision, Closed messages).
@MainActor
final class RemoteApprovalDecisionTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
        try await harness.pairApprover()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    private func outstandingRead() async throws -> (BrokerPendingApproval, VerifiedApprovalMessage) {
        let pending = try harness.submitRead()
        try await harness.waitForRequests(harness.macSent(.approvalRequest).count + 1)
        let requests = try await harness.phoneRequests()
        return (pending, try XCTUnwrap(requests.last))
    }

    // MARK: Applying

    func testAllowOnceAppliesThroughTheVaultAndClosesWithOutcomeOne() async throws {
        let (pending, request) = try await outstandingRead()
        try await harness.phone.decide(.allowOnce, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .approved)
        let closed = try await harness.phoneClosed()
        XCTAssertEqual(closed.map(\.outcome), [.applied])
        XCTAssertEqual(closed.first?.appliedCode, .allowOnce)
        XCTAssertEqual(closed.first?.appliedDuration, 0)
        XCTAssertEqual(closed.first?.requestDigest, request.digest)
        XCTAssertEqual(harness.coordinator.lastRemoteDecision,
                       RemoteAppliedDecision(requestID: pending.requestID, deviceName: "Synthetic Phone", approved: true))
        XCTAssertNil(harness.coordinator.remoteRequests[pending.requestID])
        XCTAssertFalse(harness.script.activityHeld)
    }

    func testTimedAllowanceReportsTheGrantedSeconds() async throws {
        let (pending, request) = try await outstandingRead()
        try await harness.phone.decide(.timedAllowance, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .approved)
        let closed = try await harness.phoneClosed()
        XCTAssertEqual(closed.map(\.outcome), [.applied])
        XCTAssertEqual(closed.first?.appliedCode, .timedAllowance)
        XCTAssertEqual(closed.first?.appliedDuration, 1_800)
    }

    func testDenyOnlyDenies() async throws {
        let (pending, request) = try await outstandingRead()
        try await harness.phone.decide(.deny, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .denied)
        let closed = try await harness.phoneClosed()
        XCTAssertEqual(closed.first?.outcome, .applied)
        XCTAssertEqual(closed.first?.appliedCode, .deny)
        XCTAssertEqual(harness.coordinator.lastRemoteDecision?.approved, false)
    }

    // MARK: Refusals (checks 2, 4 and 5)

    private func assertRefusedWithoutEffect(_ pending: BrokerPendingApproval, file: StaticString = #filePath,
                                            line: UInt = #line) throws {
        XCTAssertEqual(try harness.state(pending), .pending, file: file, line: line)
        XCTAssertTrue(harness.refusals.contains(.bindingMismatch), file: file, line: line)
        XCTAssertEqual(harness.entries(pending).count, 1, file: file, line: line)
        XCTAssertEqual(harness.entries(pending).first?.decided, false, "the entry stays as it was", file: file, line: line)
        XCTAssertTrue(harness.macSent(.approvalClosed).isEmpty, file: file, line: line)
    }

    func testDecisionWithoutAnOutstandingEntryIsRefused() async throws {
        let (pending, request) = try await outstandingRead()
        let payload = try await harness.signedDecision(harness.phone, code: .allowOnce, ceiling: 0, digest: request.digest)
        try await harness.phone.send(try await harness.phoneSeal(harness.phone, kind: .approvalDecision, payload: payload))
        await harness.coordinator.refresh()
        try assertRefusedWithoutEffect(pending)
    }

    func testDecisionOverAnotherDigestIsRefused() async throws {
        let (pending, request) = try await outstandingRead()
        let responseID = try XCTUnwrap(request.approvalRequest?.responseID)
        let payload = try await harness.signedDecision(harness.phone, code: .allowOnce, ceiling: 0, digest: Data(count: 32))
        try await harness.phone.send(try await harness.phoneSeal(harness.phone, kind: .approvalDecision, payload: payload,
                                                                 messageID: responseID))
        try await harness.macFetches()
        try assertRefusedWithoutEffect(pending)
    }

    func testCorrectlySignedAllowAgainstADenyOnlyOfferIsRefused() async throws {
        let unavailable = BrokerApprovalOperationRequest.Display(
            commandLine: "/usr/bin/true", workingDirectory: nil, executableBasename: "true",
            environmentVariables: nil, temporaryFileVariables: nil)
        let pending = try harness.submitDirect(.read, display: unavailable)
        try await harness.waitForRequests(1)
        let fetched1 = try await harness.phoneRequests()

        let request = try XCTUnwrap(fetched1.last)
        XCTAssertEqual(request.approvalRequest?.offers, .denyOnly)
        let payload = try await harness.signedDecision(harness.phone, code: .allowOnce, ceiling: 0, digest: request.digest)
        try await harness.phone.send(try await harness.phoneSeal(harness.phone, kind: .approvalDecision, payload: payload,
                                                                 messageID: XCTUnwrap(request.approvalRequest?.responseID)))
        try await harness.macFetches()
        try assertRefusedWithoutEffect(pending)
    }

    func testTimedCodeWithAnotherDurationThanOfferedIsRefused() async throws {
        let (pending, request) = try await outstandingRead()
        XCTAssertEqual(request.approvalRequest?.timedDuration, 1_800)
        let payload = try await harness.signedDecision(harness.phone, code: .timedAllowance, ceiling: 900,
                                                       digest: request.digest)
        try await harness.phone.send(try await harness.phoneSeal(harness.phone, kind: .approvalDecision, payload: payload,
                                                                 messageID: XCTUnwrap(request.approvalRequest?.responseID)))
        try await harness.macFetches()
        try assertRefusedWithoutEffect(pending)
    }

    func testKindsOnlyTheMacSendsAreRefused() async throws {
        let (pending, request) = try await outstandingRead()
        let fetched2 = try await harness.phone.pairedDevices()

        let mac = try XCTUnwrap(fetched2.first)
        let closed = try harness.phone.messenger.sealer.sealApprovalClosed(.expired, requestDigest: request.digest, to: mac)
        try await harness.phone.send(closed.envelope)
        await harness.coordinator.refresh()
        XCTAssertTrue(harness.refusals.contains(.unexpectedKind))
        XCTAssertEqual(try harness.state(pending), .pending)
    }

    // MARK: Closing

    func testEveryApproverThatHadTheRequestOpenLearnsHowItEnded() async throws {
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        try await harness.enableApprover(second)
        let pending = try harness.submitRead()
        try await harness.waitForRequests(harness.macSent(.approvalRequest).count + 2)
        let fetched3 = try await harness.phoneRequests()

        let request = try XCTUnwrap(fetched3.last)
        let secondRequests = try await harness.phoneRequests(second)
        let other = try XCTUnwrap(secondRequests.last)
        try await harness.phone.decide(.allowOnce, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .approved)
        let outcomes1 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes1, [.applied])
        let secondClosed = try await harness.phoneClosed(second)
        XCTAssertEqual(secondClosed.map(\.outcome), [.decidedOnAnotherApprover])
        XCTAssertEqual(secondClosed.first?.appliedCode, nil)
        // The second approver's late decision finds no entry and changes nothing.
        try await second.decide(.deny, on: other)
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .approved)
        XCTAssertTrue(harness.refusals.contains(.bindingMismatch))
    }

    func testDecisionOnTheMacClosesWithOutcomeTwo() async throws {
        let (pending, request) = try await outstandingRead()
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        harness.coordinator.approvalRequestsChanged()
        let outcomes2 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes2, [.decidedOnMac])
        // A decision that arrives after the request left pending changes nothing.
        try await harness.phone.decide(.allowOnce, on: request)
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .denied)
    }

    func testExpiryClosesWithOutcomeFour() async throws {
        let (pending, _) = try await outstandingRead()
        harness.clock.advance(by: 301)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(try harness.state(pending), .expired)
        let outcomes3 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes3, [.expired])
        XCTAssertFalse(harness.script.activityHeld)
    }

    func testCancellationAndPauseCloseWithOutcomeFive() async throws {
        let (first, _) = try await outstandingRead()
        _ = try harness.vault.approvalRequests.cancel(requestID: first.requestID, capability: first.capability)
        harness.coordinator.approvalRequestsChanged()
        let outcomes4 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes4, [.cancelled])
        _ = try await outstandingRead()
        try harness.vault.pauseAgentAccess(using: .allow)
        harness.coordinator.approvalRequestsChanged()
        let outcomes5 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes5, [.cancelled, .cancelled])
    }

    func testDecisionThatCannotApplyAsSignedGetsOutcomeSixAndAReplacement() async throws {
        let (pending, request) = try await outstandingRead()
        let original = try XCTUnwrap(request.approvalRequest)
        try await harness.phone.decide(.timedAllowance, on: request)
        // Timed allowances were turned off after the request was sealed.
        try harness.vault.updateTimedAllowance(enabled: false, minutes: 30)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .pending, "nothing applied")
        let outcomes6 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes6, [.notApplied])
        try await harness.waitForRequests(2)
        let fetched4 = try await harness.phoneRequests()

        let replacement = try XCTUnwrap(fetched4.last?.approvalRequest)
        XCTAssertNotEqual(replacement.responseID, original.responseID)
        XCTAssertEqual(replacement.offers, .denyOrAllowOnce, "the current offers")
        XCTAssertEqual(replacement.deadline, original.deadline, "the original deadline")
        XCTAssertEqual(replacement.bindingDigest, original.bindingDigest)
        XCTAssertEqual(harness.entries(pending).count, 1)
        // The replacement can be decided.
        try await harness.phone.decide(.allowOnce, on: XCTUnwrap(harness.phone.requests.last))
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .approved)
    }

    func testReplacementTakesItsPredecessorsPlaceInTheLimit() async throws {
        for _ in 0..<16 { try harness.submitDirect(.read, display: DeviceCoordinatorHarness.syntheticDisplay) }
        try await harness.waitForRequests(16)
        let requests = try await harness.phoneRequests()
        let first = try XCTUnwrap(requests.first)
        try await harness.phone.decide(.timedAllowance, on: first)
        try harness.vault.updateTimedAllowance(enabled: false, minutes: 30)
        try await harness.macFetches()
        XCTAssertEqual(harness.coordinator.outstandingCount(for: harness.phone.deviceID), 16,
                       "the replacement was sealed in the same step that removed its predecessor")
        try harness.submitDirect(.read, display: DeviceCoordinatorHarness.syntheticDisplay)
        try await harness.waitForRequests(17)
        XCTAssertEqual(harness.coordinator.outstandingCount(for: harness.phone.deviceID), 16)
        XCTAssertEqual(harness.macSent(.approvalRequest).count, 17, "16 requests and one replacement")
    }

    func testStaleGenerationEndsOnlyTheRequestsSealedUnderIt() async throws {
        let (first, _) = try await outstandingRead()
        let stale = try XCTUnwrap(harness.entries(first).first)
        harness.coordinator.remoteRequests[first.requestID]?.entries[0].decided = true
        harness.coordinator.remoteRequests[first.requestID]?.applying = 1
        // Turned off and on again while that decision is being applied.
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        await harness.coordinator.disableApprover(row)
        try await harness.enableApprover(harness.phone)
        let (second, _) = try await outstandingRead()
        XCTAssertNotEqual(harness.entries(second).first?.generation, stale.generation)
        harness.coordinator.finishRemoteDecision(.outcome(.approverInactive), code: .allowOnce, entry: stale,
                                                 requestID: first.requestID, deviceName: "Synthetic Phone")
        XCTAssertEqual(harness.entries(second).count, 1, "the newer generation's request stays open")
        let outcomes = try await harness.phoneClosed().map(\.outcome)
        XCTAssertEqual(outcomes, [.cancelled])
    }

    func testInactiveApproverEndsItsOtherOutstandingRequests() async throws {
        let (first, request) = try await outstandingRead()
        let (second, _) = try await outstandingRead()
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        // The Broker no longer holds the generation recorded at sealing.
        harness.vault.approvalRequests.removeActiveApprover(pairingID: row.pairingID.rawValue)
        try await harness.phone.decide(.deny, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(first), .pending)
        XCTAssertEqual(try harness.state(second), .pending)
        let outcomes7 = try await harness.phoneClosed().map(\.outcome)

        XCTAssertEqual(outcomes7, [.cancelled, .cancelled])
        XCTAssertTrue(harness.entries(first).isEmpty)
        XCTAssertTrue(harness.entries(second).isEmpty)
    }

    func testRequestEndedDuringARevokedApproversDecisionStillClosesForTheOthers() async throws {
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        try await harness.enableApprover(second)
        let pending = try harness.submitRead()
        try await harness.waitForRequests(harness.macSent(.approvalRequest).count + 2)
        let deciding = try XCTUnwrap(harness.entries(pending).first { $0.approverID == harness.phone.deviceID })
        // The first approver's decision passed its checks and is being applied...
        let index = try XCTUnwrap(harness.entries(pending).firstIndex { $0.responseID == deciding.responseID })
        harness.coordinator.remoteRequests[pending.requestID]?.entries[index].decided = true
        harness.coordinator.remoteRequests[pending.requestID]?.applying = 1
        // ...when the request is denied on the Mac and the approver is revoked.
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        harness.coordinator.approvalRequestsChanged()
        XCTAssertNotNil(harness.coordinator.remoteRequests[pending.requestID], "it waits for the decision being applied")
        harness.coordinator.finishRemoteDecision(.outcome(.approverInactive), code: .allowOnce, entry: deciding,
                                                 requestID: pending.requestID, deviceName: "Synthetic Phone")
        XCTAssertNil(harness.coordinator.remoteRequests[pending.requestID])
        let outcomes = try await harness.phoneClosed().map(\.outcome)
        XCTAssertEqual(outcomes, [.cancelled])
        let others = try await harness.phoneClosed(second).map(\.outcome)
        XCTAssertEqual(others, [.decidedOnMac])
        XCTAssertFalse(harness.script.activityHeld)
        XCTAssertFalse(harness.coordinator.remoteNeedsLoop)
    }

    func testLocalDecisionThatLosesToARemoteOneShowsNoError() async throws {
        let (pending, request) = try await outstandingRead()
        try await harness.phone.decide(.allowOnce, on: request)
        try await harness.macFetches()
        XCTAssertThrowsError(try harness.vault.decideAgentApproval(
            requestID: pending.requestID, capability: pending.capability, decision: .deny)) { error in
            XCTAssertEqual(error as? BrokerApprovalError, .decidedElsewhere)
            XCTAssertFalse(LocalApprovalDecision.showsError(error))
        }
        XCTAssertTrue(LocalApprovalDecision.showsError(BrokerApprovalError.invalidDecision))
    }
}
