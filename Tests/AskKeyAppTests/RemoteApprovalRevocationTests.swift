import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Every path that ends or suspends an approver's authority takes it out of
/// the Broker's active-approver set first (ADR 0014 → Revocation, Replay and
/// restarts).
@MainActor
final class RemoteApprovalRevocationTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!
    private var pairingID: Data!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
        try await harness.pairApprover()
        pairingID = try XCTUnwrap(harness.coordinator.devices.first).pairingID.rawValue
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    private var generation: UInt64? { harness.vault.approvalRequests.activeApproverGeneration(pairingID: pairingID) }

    private func outstandingRead() async throws -> (BrokerPendingApproval, VerifiedApprovalMessage) {
        let pending = try harness.submitRead()
        try await harness.waitForRequests(harness.macSent(.approvalRequest).count + 1)
        let requests = try await harness.phoneRequests()
        return (pending, try XCTUnwrap(requests.last))
    }

    /// Records, whenever the Mac saves a closing message, whether the
    /// approver was still in the Broker's set.
    private func watchClosingOrder() -> ClosingOrder {
        let order = ClosingOrder()
        let approvals = harness.vault.approvalRequests
        let id = pairingID!
        harness.transport.interceptor = { envelope in
            if envelope.kind == Int64(MessageKind.approvalClosed.rawValue) {
                order.record(approvals.activeApproverGeneration(pairingID: id) != nil)
            }
            return .deliver
        }
        return order
    }

    private func assertLaterDecisionsRefused(_ request: VerifiedApprovalMessage, _ pending: BrokerPendingApproval,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        try await harness.phone.decide(.deny, on: request)
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .pending, "a later Deny is refused too", file: file, line: line)
    }

    func testTurningApprovalOffRevokesBeforeClosing() async throws {
        let (pending, request) = try await outstandingRead()
        let order = watchClosingOrder()
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        let disabled = await harness.coordinator.disableApprover(row)
        XCTAssertTrue(disabled)
        XCTAssertNil(generation)
        XCTAssertEqual(harness.coordinator.devices.first?.isApprover, false)
        let outcomes = try await harness.phoneClosed().map(\.outcome)
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertEqual(order.stillActive, [false])
        try await assertLaterDecisionsRefused(request, pending)
        // A new request no longer goes to it.
        try harness.submitRead()
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(harness.macSent(.approvalRequest).count, 1)
    }

    func testRemovalRevokesBeforeClosing() async throws {
        let (pending, _) = try await outstandingRead()
        let order = watchClosingOrder()
        let removed = await harness.coordinator.removeDevice(harness.phone.deviceID)
        XCTAssertTrue(removed)
        XCTAssertNil(generation)
        try await harness.waitUntil { harness.macSentClosedSettled }
        XCTAssertEqual(harness.macSent(.approvalClosed).count, 1)
        XCTAssertEqual(order.stillActive, [false])
        XCTAssertTrue(harness.entries(pending).isEmpty)
    }

    func testUnpairNoticeRevokesThroughTheRemovalHook() async throws {
        let (pending, _) = try await outstandingRead()
        let order = watchClosingOrder()
        try await harness.phone.messenger.removeDevice(XCTUnwrap(harness.macDeviceID))
        await harness.coordinator.refresh()
        XCTAssertNil(generation)
        XCTAssertTrue(harness.coordinator.devices.isEmpty)
        try await harness.waitUntil { harness.macSentClosedSettled }
        XCTAssertEqual(order.stillActive, [false])
        XCTAssertTrue(harness.entries(pending).isEmpty)
    }

    func testIdentityResetEmptiesTheSet() async throws {
        _ = try await outstandingRead()
        harness.backend.restoreFails = true
        await harness.relaunch()
        XCTAssertEqual(harness.coordinator.availability, .identityUnusable)
        XCTAssertNotNil(generation, "this test's Broker outlives the relaunch")
        let reset = await harness.coordinator.resetIdentity()
        XCTAssertTrue(reset)
        XCTAssertNil(generation)
    }

    func testAccountChangeSuspendsApproversUntilTheAccountReturns() async throws {
        let (pending, request) = try await outstandingRead()
        let before = try XCTUnwrap(generation)
        let sent = harness.transport.sentEnvelopes.count
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.coordinator.account, .accountChanged)
        XCTAssertNil(generation)
        XCTAssertTrue(harness.coordinator.remoteRequests.values.allSatisfy { $0.entries.isEmpty && $0.phase == .stayingOnMac })
        XCTAssertFalse(harness.script.activityHeld)
        XCTAssertEqual(harness.transport.sentEnvelopes.count, sent, "nothing is sent while the account is unavailable")
        XCTAssertTrue(harness.coordinator.devices.first?.isApprover == true, "the flag stays")

        harness.backend.accountState = .available(userRecordName: "_synthetic-account-1")
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.coordinator.account, .available)
        let after = try XCTUnwrap(generation)
        XCTAssertGreaterThan(after, before, "the set is loaded again with a new generation")
        harness.coordinator.approvalRequestsChanged()
        await harness.coordinator.remoteApprovalTick()
        XCTAssertEqual(harness.macSent(.approvalRequest).count, 1, "the earlier request stays on the Mac")
        // The decision for the request sealed before the change finds no entry.
        try await harness.phone.decide(.allowOnce, on: request)
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .pending)
    }

    func testLocalEraseEmptiesTheSetFirst() async throws {
        _ = try await outstandingRead()
        harness.vault.stopDeviceServicesForLocalErase()
        XCTAssertNil(generation)
        harness.coordinator.stopForLocalErase()
        XCTAssertTrue(harness.coordinator.remoteRequests.isEmpty)
        XCTAssertFalse(harness.script.activityHeld)
    }

    func testDecisionArrivingAfterARestartIsRefused() async throws {
        let (pending, request) = try await outstandingRead()
        let sealed = try await harness.phone.decide(.allowOnce, on: request)
        await harness.relaunch()
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .pending)
        XCTAssertTrue(harness.refusals.contains(.bindingMismatch))
        try await harness.phone.send(sealed.envelope)
        await harness.coordinator.refresh()
        XCTAssertEqual(try harness.state(pending), .pending, "a re-inserted decision is refused")
    }
}

final class ClosingOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func record(_ active: Bool) { lock.withLock { values.append(active) } }
    var stillActive: [Bool] { lock.withLock { values } }
}
