import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// What the coordinator tells the approval panel's footer (ADR 0014 → Mac
/// App, amended by #345): the countdown only while an eligible request waits
/// for an approver with room, the sent hint only while a saved copy is
/// outstanding, and no hint in every other case. The footer
/// only reads; none of these steps changes what is sent.
@MainActor
final class RemoteApprovalFooterHintTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    private func hint(_ pending: BrokerPendingApproval) -> RemoteApprovalFooterHint? {
        harness.coordinator.remoteFooterHint(for: pending.requestID)
    }

    /// An unlocked Mac with an approver: a read waits for its 20-second send.
    private func waitingRead() async throws -> (BrokerPendingApproval, Date) {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        let sendAt = harness.clock.now().addingTimeInterval(DeviceCoordinator.remoteSendDelay)
        return (try harness.submitRead(), sendAt)
    }

    private func passTheTwentySecondMark() async throws {
        harness.clock.advance(by: DeviceCoordinator.remoteSendDelay)
        await harness.coordinator.remoteApprovalTick()
    }

    func testTheCountdownRunsUntilTheSendThenTheSavedCopyGivesTheSentHint() async throws {
        let (pending, sendAt) = try await waitingRead()
        for _ in 0..<19 {
            XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
            harness.clock.advance(by: 1)
            await harness.coordinator.remoteApprovalTick()
        }
        XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
        harness.clock.advance(by: 1)
        harness.coordinator.reconcileRemoteRequests()
        XCTAssertEqual(harness.coordinator.remoteRequests[pending.requestID]?.phase, .sending)
        XCTAssertNil(hint(pending), "unchanged while the request is being sealed")
        try await harness.waitForRequests(1)
        try await harness.waitUntil { harness.entries(pending).first?.sentAt != nil }
        XCTAssertEqual(hint(pending), .sent)
        XCTAssertTrue(harness.coordinator.wasSentToApprover(pending.requestID), "the same saved state as Details' Sent to")
    }

    func testARequestDecidedOnTheMacWithinTwentySecondsNeverSaysAlsoOnIPhone() async throws {
        let (pending, sendAt) = try await waitingRead()
        harness.clock.advance(by: 10)
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
        _ = try harness.vault.decideAgentApproval(requestID: pending.requestID, capability: pending.capability, decision: .deny)
        harness.coordinator.approvalRequestsChanged()
        var seen: [RemoteApprovalFooterHint?] = [hint(pending)]
        for _ in 0..<15 {
            harness.clock.advance(by: 1)
            await harness.coordinator.remoteApprovalTick()
            seen.append(hint(pending))
        }
        XCTAssertTrue(seen.allSatisfy { $0 == nil })
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
    }

    func testWithoutAnApproverTheFooterIsAlwaysUnchanged() async throws {
        try await harness.pairPhone()
        await harness.coordinator.removeDevice(harness.phone.deviceID)
        try await harness.addUnflaggedEntry(for: harness.phone, name: "Synthetic Phone")
        try harness.addCredential()
        harness.script.screenUnlocked = true
        let pending = try harness.submitRead()
        for _ in 0..<25 {
            XCTAssertNil(hint(pending))
            harness.clock.advance(by: 1)
            await harness.coordinator.remoteApprovalTick()
        }
        XCTAssertNil(hint(pending))
    }

    func testRemovingTheLastApproverDuringTheWaitRestoresTheFooter() async throws {
        let (pending, sendAt) = try await waitingRead()
        XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
        await harness.coordinator.removeDevice(harness.phone.deviceID)
        XCTAssertNil(hint(pending))
        try await passTheTwentySecondMark()
        XCTAssertNil(hint(pending))
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
    }

    func testAnUnavailableAccountDuringTheWaitRestoresTheFooter() async throws {
        let (pending, sendAt) = try await waitingRead()
        XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
        harness.backend.accountState = .temporarilyUnavailable
        await harness.coordinator.devicesOpened()
        XCTAssertNotEqual(harness.coordinator.account, .available)
        XCTAssertNil(hint(pending))
    }

    func testPausingAgentAccessDuringTheWaitRestoresTheFooter() async throws {
        let (pending, sendAt) = try await waitingRead()
        XCTAssertEqual(hint(pending), .waiting(sendAt: sendAt))
        try harness.vault.pauseAgentAccess(using: .allow)
        XCTAssertNil(hint(pending))
    }

    func testARequestWhoseDeadlineComesBeforeItsSendNeverCountsDown() async throws {
        let (pending, _) = try await waitingRead()
        let deadline = try XCTUnwrap(pending.expiresAt)
        harness.coordinator.remoteRequests[pending.requestID]?.phase = .waiting(sendAt: deadline.addingTimeInterval(1))
        XCTAssertNil(hint(pending), "a request that will not be sealed never promises the iPhone")
    }

    func testWhenEveryApproverIsFullTheFooterIsUnchangedUntilOneHasRoom() async throws {
        try await harness.pairApprover()
        var sent: [BrokerPendingApproval] = []
        for _ in 0..<DeviceCoordinator.maximumOutstandingPerApprover {
            sent.append(try harness.submitDirect(.read, display: DeviceCoordinatorHarness.syntheticDisplay))
        }
        try await harness.waitForRequests(DeviceCoordinator.maximumOutstandingPerApprover)
        harness.script.screenUnlocked = true
        let sendAt = harness.clock.now().addingTimeInterval(DeviceCoordinator.remoteSendDelay)
        let waiting = try harness.submitRead()
        guard case .waiting = harness.coordinator.remoteRequests[waiting.requestID]?.phase else {
            return XCTFail("the request is eligible and waits")
        }
        XCTAssertNil(hint(waiting), "no approver has room under its limit")
        let first = try XCTUnwrap(sent.first)
        _ = try harness.vault.decideAgentApproval(requestID: first.requestID, capability: first.capability, decision: .deny)
        harness.coordinator.approvalRequestsChanged()
        XCTAssertEqual(hint(waiting), .waiting(sendAt: sendAt), "a closed copy makes room")
    }

    func testAFirstSendThatIsRetriedKeepsTheFooterUnchangedUntilItIsSaved() async throws {
        let (pending, _) = try await waitingRead()
        harness.transport.failNextSends(with: [.networkUnavailable])
        try await passTheTwentySecondMark()
        try await harness.waitForRequests(1)
        try await harness.waitUntil {
            if case .retry = harness.entries(pending).first?.delivery { return true }
            return false
        }
        XCTAssertNil(harness.entries(pending).first?.sentAt)
        XCTAssertNil(hint(pending), "the iPhone's inbox does not hold the request yet")
        harness.clock.advance(by: DeviceCoordinator.remoteRetryInterval)
        await harness.coordinator.remoteApprovalTick()
        try await harness.waitUntil { harness.entries(pending).first?.sentAt != nil }
        XCTAssertEqual(hint(pending), .sent)
    }

    func testOnceEveryCopyClosedTheFooterIsUnchanged() async throws {
        let (pending, _) = try await waitingRead()
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        try await passTheTwentySecondMark()
        try await harness.waitForRequests(2)
        try await harness.waitUntil { harness.entries(pending).allSatisfy { $0.sentAt != nil } }
        XCTAssertEqual(harness.entries(pending).count, 2)
        XCTAssertEqual(hint(pending), .sent)
        await harness.coordinator.removeDevice(second.deviceID)
        XCTAssertEqual(harness.entries(pending).count, 1)
        XCTAssertEqual(hint(pending), .sent, "one approver still has the request")
        await harness.coordinator.removeDevice(harness.phone.deviceID)
        XCTAssertTrue(harness.entries(pending).isEmpty)
        XCTAssertNil(hint(pending))
        XCTAssertEqual(try harness.state(pending), .pending, "the request stays on the Mac")
    }

    func testARequestTheIPhoneDecidedNoLongerSaysAlsoOnIPhone() async throws {
        let (pending, _) = try await waitingRead()
        try await passTheTwentySecondMark()
        try await harness.waitForRequests(1)
        try await harness.waitUntil { harness.entries(pending).first?.sentAt != nil }
        XCTAssertEqual(hint(pending), .sent)
        let requests = try await harness.phoneRequests()
        let request = try XCTUnwrap(requests.first)
        try await harness.phone.decide(.deny, on: request)
        try await harness.macFetches()
        XCTAssertEqual(try harness.state(pending), .denied)
        XCTAssertNil(hint(pending))
    }
}
