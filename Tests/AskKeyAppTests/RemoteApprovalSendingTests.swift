import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// When a request goes to an approver, what it offers, and the schedules
/// around it (ADR 0014 → When a request goes to an approver, Sending and the
/// return path).
@MainActor
final class RemoteApprovalSendingTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    func testWithoutAnApproverNothingIsSentAndNoCloudKitRequestIsMade() async throws {
        try await harness.pairPhone()
        try harness.addCredential()
        let sentBefore = harness.transport.sentEnvelopes.count
        try harness.submitRead()
        harness.script.screenUnlocked = true
        try harness.submitRead()
        for _ in 0..<25 {
            harness.clock.advance(by: 1)
            await harness.coordinator.remoteApprovalTick()
        }
        harness.coordinator.screenDidLock()
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(harness.transport.sentEnvelopes.count, sentBefore)
        XCTAssertTrue(harness.transport.namedFetchRequests.isEmpty)
        XCTAssertEqual(harness.script.activityBegins, 0)
    }

    func testRequestThatAppearedBeforeApprovalWasOnStaysOnTheMac() async throws {
        try await harness.pairPhone()
        try harness.addCredential()
        let pending = try harness.submitRead()
        try await harness.enableApprover(harness.phone)
        harness.coordinator.approvalRequestsChanged()
        await harness.coordinator.remoteApprovalTick()
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
        XCTAssertEqual(harness.coordinator.remoteRequests[pending.requestID]?.phase, .stayingOnMac)
        try harness.submitRead()
        try await harness.waitForRequests(1)
    }

    func testLockedScreenSendsAtOnce() async throws {
        try await harness.pairApprover()
        let created = harness.clock.now()
        let pending = try harness.submitRead()
        try await harness.waitForRequests(1)
        let entry = try XCTUnwrap(harness.entries(pending).first)
        XCTAssertEqual(entry.sealedAt, created, "sealed on creation, before the clock moved")
        let requests = try await harness.phoneRequests()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first?.approvalRequest)
        XCTAssertEqual(request.credentialName, DeviceCoordinatorHarness.credentialName)
        XCTAssertEqual(request.requesterName, "Synthetic Agent")
        XCTAssertEqual(request.executableName, "true")
        XCTAssertEqual(request.deliveryRows, [ApprovalDeliveryRow(kind: .environmentVariable, label: "",
                                                                  variable: DeviceCoordinatorHarness.credentialName)])
        XCTAssertEqual(request.deadline, Date(timeIntervalSince1970: floor(try XCTUnwrap(pending.expiresAt).timeIntervalSince1970)))
        XCTAssertEqual(requests.first?.digest, entry.requestDigest)
        XCTAssertNotNil(harness.coordinator.remoteApprovals[pending.requestID]?.approvers.first?.sentAt)
    }

    func testUnlockedScreenWaitsTwentySeconds() async throws {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        let pending = try harness.submitRead()
        harness.clock.advance(by: 19)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
        XCTAssertTrue(harness.script.activityHeld, "the activity is held from eligibility")
        harness.clock.advance(by: 1)
        await harness.coordinator.remoteApprovalTick()
        try await harness.waitForRequests(1)
        XCTAssertEqual(harness.entries(pending).count, 1)
    }

    func testLockingDuringTheWaitSendsAtOnce() async throws {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        try harness.submitRead()
        harness.clock.advance(by: 5)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
        harness.coordinator.screenDidLock()
        try await harness.waitForRequests(1)
    }

    func testRequestDecidedOnTheMacWithinTwentySecondsNeverLeaves() async throws {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        let pending = try harness.submitRead()
        harness.clock.advance(by: 10)
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        harness.clock.advance(by: 10)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
        XCTAssertFalse(harness.script.activityHeld)
    }

    func testDeliveryRereadsTheStatusJustBeforeSealing() async throws {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        let pending = try harness.submitRead()
        // Decided after the 20-second check chose to send, before sealing.
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        harness.coordinator.remoteRequests[pending.requestID]?.phase = .sending
        await harness.coordinator.deliverRemoteRequest(pending.requestID)
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
    }

    func testOnlyReadRequestsWithADisplayLeaveTheMac() async throws {
        try await harness.pairApprover()
        try harness.submitDirect(.create)
        try harness.submitDirect(.read, display: nil)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(harness.coordinator.remoteRequests.count, 2)
        XCTAssertTrue(harness.coordinator.remoteRequests.values.allSatisfy { $0.phase == .stayingOnMac })
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
    }

    func testOffersFollowTheTimedAllowanceSettings() async throws {
        try await harness.pairApprover()
        // Defaults: timed allowances on for 30 minutes, End Timed Allow on Lock off.
        try harness.submitRead()
        try await harness.waitForRequests(1)
        try harness.vault.updateTimedAllowance(enabled: false, minutes: 30)
        try harness.submitRead()
        try await harness.waitForRequests(2)
        try harness.vault.updateTimedAllowance(enabled: true, minutes: 15)
        try harness.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
        try harness.submitRead()
        try await harness.waitForRequests(3)
        harness.script.screenUnlocked = true
        try harness.submitRead()
        harness.clock.advance(by: 20)
        await harness.coordinator.remoteApprovalTick()
        try await harness.waitForRequests(4)
        let requests = try await harness.phoneRequests().compactMap(\.approvalRequest)
        XCTAssertEqual(requests.map(\.offers), [.all, .denyOrAllowOnce, .denyOrAllowOnce, .denyOrAllowOnce])
        XCTAssertEqual(requests.map(\.timedDuration), [1_800, 0, 0, 0])
    }

    func testShortenedDisplayAndUnavailableMetadataOfferOnlyDeny() async throws {
        try await harness.pairApprover()
        try harness.submitRead(command: ["/usr/bin/true", String(repeating: "x", count: 4_000), String(repeating: "y", count: 4_000)])
        let unavailable = BrokerApprovalOperationRequest.Display(
            commandLine: "/usr/bin/true", workingDirectory: nil, executableBasename: "true",
            environmentVariables: nil, temporaryFileVariables: nil)
        try harness.submitDirect(.read, display: unavailable)
        try await harness.waitForRequests(2)
        let requests = try await harness.phoneRequests().compactMap(\.approvalRequest)
        XCTAssertEqual(requests.map(\.offers), [.denyOnly, .denyOnly])
        XCTAssertTrue(requests[0].shortened.contains(.commandLine))
        XCTAssertTrue(requests[1].deliveryMetadataUnavailable)
        let recorded = harness.coordinator.remoteRequests.values.flatMap(\.entries).map(\.offers)
        XCTAssertEqual(recorded, [.denyOnly, .denyOnly], "the outstanding entry records what was sealed")
    }

    func testAtMostSixteenRequestsAreOutstandingPerApprover() async throws {
        try await harness.pairApprover()
        for _ in 0..<17 { try harness.submitDirect(.read, display: DeviceCoordinatorHarness.syntheticDisplay) }
        try await harness.waitForRequests(16)
        XCTAssertEqual(harness.coordinator.remoteRequests.values.filter { $0.phase == .stayingOnMac }.count, 1)
        XCTAssertEqual(harness.macSent(.approvalRequest).count, 16)
        XCTAssertEqual(harness.coordinator.outstandingCount(for: harness.phone.deviceID), 16)
    }

    func testEachApproverGetsItsOwnSealingAndResendsReuseItsBytes() async throws {
        try await harness.pairApprover()
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        try await harness.enableApprover(second)
        harness.transport.failNextSends(with: [.networkUnavailable])
        let pending = try harness.submitRead()
        try await harness.waitForRequests(2)
        let entries = harness.entries(pending)
        XCTAssertEqual(entries.count, 2)
        guard entries.count == 2 else { return }
        XCTAssertNotEqual(entries[0].responseID, entries[1].responseID)
        XCTAssertNotEqual(entries[0].requestDigest, entries[1].requestDigest)
        let failed = try XCTUnwrap(entries.first { if case .retry = $0.delivery { return true }; return false })
        harness.clock.advance(by: 2)
        await harness.coordinator.remoteApprovalTick()
        try await harness.waitUntil { harness.macSent(.approvalRequest).count == 3 }
        let resent = harness.macSent(.approvalRequest).filter { $0.recordName == failed.envelope.recordName }
        XCTAssertEqual(resent.count, 2)
        XCTAssertEqual(resent.first, resent.last, "a resend uses the same bytes")
        let firstDigests = try await harness.phoneRequests().map(\.digest)
        let secondDigests = try await harness.phoneRequests(second).map(\.digest)
        XCTAssertEqual(Set(firstDigests + secondDigests), Set(entries.map(\.requestDigest)))
    }

    func testKnownRecordsAreFetchedEverySecondForAMinuteThenEveryThreeSeconds() async throws {
        try await harness.pairApprover()
        try harness.submitRead()
        try await harness.waitForRequests(1)
        var fetchTimes: [Int] = []
        for second in 1...72 {
            harness.clock.advance(by: 1)
            let before = harness.transport.namedFetchRequests.count
            await harness.coordinator.remoteApprovalTick()
            if harness.transport.namedFetchRequests.count > before { fetchTimes.append(second) }
        }
        XCTAssertEqual(fetchTimes, Array(1...60) + [63, 66, 69, 72])
        let names = try XCTUnwrap(harness.transport.namedFetchRequests.first)
        let entry = try XCTUnwrap(harness.coordinator.remoteRequests.values.first?.entries.first)
        XCTAssertEqual(Set(names), [entry.responseID.text, entry.receiptID.text])
    }

    func testFetchesHonorRetryAfter() async throws {
        try await harness.pairApprover()
        try harness.submitRead()
        try await harness.waitForRequests(1)
        harness.backend.askNextNamedFetchesToWait([10])
        var fetchTimes: [Int] = []
        for second in 1...30 {
            harness.clock.advance(by: 1)
            if second == 12 { harness.backend.failNextNamedFetches(with: [.rateLimited(retryAfter: 7)]) }
            let before = harness.transport.namedFetchRequests.count
            await harness.coordinator.remoteApprovalTick()
            if harness.transport.namedFetchRequests.count > before { fetchTimes.append(second) }
        }
        // 1 asks for 10 s; 11 succeeds; 12 is refused with 7 s; 19 resumes.
        XCTAssertEqual(fetchTimes, [1, 11] + Array(19...30))
    }

    func testRetryAfterCountsFromTheAnswerAndPushesDoNotBreakIt() async throws {
        try await harness.pairApprover()
        try harness.submitRead()
        try await harness.waitForRequests(1)
        let clock = harness.clock
        // The fetch takes 8 seconds and then asks to wait 10.
        harness.backend.beforeFetch = { clock.advance(by: 8) }
        harness.backend.askNextNamedFetchesToWait([10])
        try await harness.macFetches()
        harness.backend.beforeFetch = nil
        let afterAnswer = harness.transport.namedFetchRequests.count
        for _ in 0..<9 {
            harness.clock.advance(by: 1)
            harness.coordinator.screenDidUnlockOrWake()
            harness.coordinator.handleRemoteNotification(FakeDeviceServicesBackend.pushHint(for: try XCTUnwrap(harness.macDeviceID)))
            await harness.coordinator.remoteApprovalTick()
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(harness.transport.namedFetchRequests.count, afterAnswer, "nothing fetched within 10 s of the answer")
        harness.clock.advance(by: 1)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(harness.transport.namedFetchRequests.count, afterAnswer + 1)
    }

    func testNamedFetchesGoInBatchesOfAtMostOneHundred() async throws {
        try await harness.pairApprover()
        let pending = try harness.submitRead()
        try await harness.waitForRequests(1)
        let template = try XCTUnwrap(harness.entries(pending).first)
        harness.coordinator.remoteRequests[pending.requestID]?.entries += (0..<59).map { _ in
            let id = MessageID.random()
            return OutstandingRemoteRequest(recipient: template.recipient, generation: template.generation,
                                            responseID: id, receiptID: ApprovalReceipt.receiptID(for: id),
                                            requestDigest: template.requestDigest, offers: template.offers,
                                            timedDuration: template.timedDuration, envelope: template.envelope,
                                            sealedAt: template.sealedAt)
        }
        let before = harness.transport.namedFetchRequests.count
        try await harness.macFetches()
        let batches = harness.transport.namedFetchRequests.dropFirst(before).map(\.count)
        XCTAssertEqual(batches, [100, 20])
    }

    func testProcessActivityIsHeldUntilNoRequestNeedsIt() async throws {
        try await harness.pairApprover()
        XCTAssertFalse(harness.script.activityHeld)
        let pending = try harness.submitRead()
        try await harness.waitForRequests(1)
        XCTAssertTrue(harness.script.activityHeld)
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertFalse(harness.script.activityHeld)
        XCTAssertEqual(harness.script.activityBegins, 1)
    }

    func testReceiptMarksTheRequestDeliveredAndIsNoLongerFetched() async throws {
        try await harness.pairApprover()
        let pending = try harness.submitRead()
        try await harness.waitForRequests(1)
        let received = try await harness.phoneRequests()
        let request = try XCTUnwrap(received.first)
        try await harness.phone.sendReceipt(for: request)
        try await harness.macFetches()
        let approver = try XCTUnwrap(harness.coordinator.remoteApprovals[pending.requestID]?.approvers.first)
        XCTAssertEqual(approver.deliveredAt, harness.clock.now())
        harness.clock.advance(by: 1)
        try await harness.macFetches()
        let entry = try XCTUnwrap(harness.entries(pending).first)
        XCTAssertEqual(harness.transport.namedFetchRequests.last, [entry.responseID.text])
    }

    func testPushRegistrationWaitsForAnIdentity() async throws {
        await harness.coordinator.devicesOpened()
        await harness.coordinator.refresh()
        XCTAssertEqual(harness.script.pushRegistrations, 0, "a Mac that never pairs registers no push")
        try await harness.pairPhone()
        XCTAssertEqual(harness.script.pushRegistrations, 1)
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.script.pushRegistrations, 1)
    }
}
