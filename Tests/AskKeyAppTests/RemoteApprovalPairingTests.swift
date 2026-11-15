import AskKeyBroker
import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Pairing makes an iPhone an approver (ADR 0014 → Approvers, decision 4 of
/// #336): it joins the Broker's active-approver set as soon as the
/// coordinator learns of the add, a flagged entry missing from the set is
/// added at the next list read, and a removal that races either wins.
@MainActor
final class RemoteApprovalPairingTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    func testANewlyPairedIPhoneJoinsTheSetWithANewGenerationWhileTheSheetShowsPaired() async throws {
        try await harness.pairPhoneLeavingSheetOpen()
        let row = try XCTUnwrap(harness.coordinator.devices.first)
        XCTAssertTrue(row.isApprover, "the add wrote the flag")
        let first = try XCTUnwrap(try harness.generation(of: harness.phone), "joined before the sheet closed")
        XCTAssertTrue(harness.script.loggedEvents.contains(.approverActivated))
        await harness.coordinator.cancelPairing()

        // A second iPhone joins alone: the first keeps its generation.
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        let added = try XCTUnwrap(try harness.generation(of: second))
        XCTAssertGreaterThan(added, first)
        XCTAssertEqual(try harness.generation(of: harness.phone), first)
    }

    /// The sheet closed while the messenger was committing the add, so the
    /// coordinator never saw the paired phase: the next list read adds it.
    func testAnIPhoneAddedAfterTheSheetClosedJoinsAtTheNextListRead() async throws {
        let code = try await harness.reachCodeEntry()
        await harness.coordinator.enterPairingCode(code)
        await harness.coordinator.confirmPairing()
        guard case .waitingForIPhoneConfirmation = harness.coordinator.pairing else {
            return XCTFail("the Mac waits for the iPhone, not \(String(describing: harness.coordinator.pairing))")
        }
        harness.coordinator.pairing = nil
        try await harness.phone.confirm()
        await harness.coordinator.refresh()
        let row = try XCTUnwrap(harness.coordinator.devices.first, "the Mac added the iPhone")
        XCTAssertTrue(row.isApprover)
        XCTAssertNil(harness.coordinator.pairing, "no sheet showed the add")
        XCTAssertNotNil(try harness.generation(of: harness.phone))
    }

    func testAFlaggedEntryMissingFromTheSetIsAddedAloneAtTheNextListRead() async throws {
        try await harness.pairApprover()
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        let kept = try XCTUnwrap(try harness.generation(of: second))
        let lost = try XCTUnwrap(try harness.generation(of: harness.phone))
        // The addition failed or the Broker lost the entry.
        let row = try XCTUnwrap(harness.coordinator.devices.first { $0.id == harness.phone.deviceID })
        harness.vault.approvalRequests.removeActiveApprover(pairingID: row.pairingID.rawValue)
        XCTAssertNil(try harness.generation(of: harness.phone))
        await harness.coordinator.refresh()
        let repaired = try XCTUnwrap(try harness.generation(of: harness.phone))
        XCTAssertGreaterThan(repaired, lost, "a new generation, never the old one")
        XCTAssertEqual(try harness.generation(of: second), kept, "the other approver keeps its generation")
        // A request goes to both.
        try harness.submitRead()
        try await harness.waitForRequests(2)
    }

    func testNoListReadAddsAnEntryWithoutTheFlag() async throws {
        try await harness.pairPhone()
        await harness.coordinator.removeDevice(harness.phone.deviceID)
        try await harness.addUnflaggedEntry(for: harness.phone, name: "Synthetic Phone")
        await harness.coordinator.refresh()
        XCTAssertEqual(harness.coordinator.devices.map(\.isApprover), [false])
        XCTAssertNil(try harness.generation(of: harness.phone))
    }

    func testNoListReadAddsAnEntryWhileTheAccountIsUnavailable() async throws {
        try await harness.pairApprover()
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.coordinator.account, .accountChanged)
        await harness.coordinator.refresh()
        XCTAssertNil(try harness.generation(of: harness.phone), "an account change suspends approvers")
    }

    /// The removal hook took the pairing out of the set, and the list still
    /// holds it until the write commits: a list read in that window must not
    /// bring it back.
    func testARemovalThatRacesTheAdditionWins() async throws {
        try await harness.pairApprover()
        let registry = try XCTUnwrap(harness.coordinator.services?.registry)
        let devices = try await registry.list().devices
        let entry = try XCTUnwrap(devices.first)
        harness.coordinator.deviceWillBeRemoved(entry)
        XCTAssertNil(try harness.generation(of: harness.phone))
        await harness.coordinator.refresh()
        XCTAssertEqual(harness.coordinator.devices.count, 1, "the write has not committed yet")
        XCTAssertNil(try harness.generation(of: harness.phone), "a list read does not undo the removal")
        harness.coordinator.pairingAdded(entry.pairingID)
        XCTAssertNil(try harness.generation(of: harness.phone), "nor does a late add notice")
    }

    /// A removal whose write failed or is still pending: reloading the set
    /// after the account returns does not bring the pairing back either.
    func testAReloadAfterAnAccountChangeSkipsAPairingWhoseRemovalBegan() async throws {
        try await harness.pairApprover()
        let registry = try XCTUnwrap(harness.coordinator.services?.registry)
        let devices = try await registry.list().devices
        let entry = try XCTUnwrap(devices.first)
        harness.coordinator.deviceWillBeRemoved(entry)
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.coordinator.account, .accountChanged)
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-1")
        await harness.coordinator.devicesOpened()
        XCTAssertEqual(harness.coordinator.account, .available)
        XCTAssertEqual(harness.coordinator.devices.count, 1, "the entry is still stored")
        XCTAssertNil(try harness.generation(of: harness.phone), "the reload skipped it")
    }

    func testAnIPhoneThatUndoesThePairingRightAfterTheAddNeverStaysInTheSet() async throws {
        // The iPhone confirms first, so the Mac adds it as soon as it confirms.
        let code = try await harness.reachCodeEntry()
        try await harness.phone.confirm()
        await harness.coordinator.enterPairingCode(code)
        await harness.coordinator.confirmPairing()
        await harness.coordinator.refresh()
        guard case .paired = harness.coordinator.pairing else {
            return XCTFail("the Mac paired, not \(String(describing: harness.coordinator.pairing))")
        }
        XCTAssertNotNil(try harness.generation(of: harness.phone))
        let pairingID = try XCTUnwrap(harness.coordinator.devices.first).pairingID
        // The iPhone cancels before it added the Mac, which undoes the pairing (ADR 0013, step 7).
        await harness.phone.cancel()
        await harness.coordinator.refresh()
        XCTAssertTrue(harness.coordinator.devices.isEmpty)
        XCTAssertNil(harness.vault.approvalRequests.activeApproverGeneration(pairingID: pairingID.rawValue))
    }

    /// The Broker's notification of a request has not reached the
    /// coordinator when the first iPhone joins: the request still stays on
    /// the Mac.
    func testARequestNotSeenYetWhenTheFirstIPhoneJoinsStaysOnTheMac() async throws {
        try harness.addCredential()
        let code = try await harness.reachCodeEntry()
        await harness.coordinator.enterPairingCode(code)
        await harness.coordinator.confirmPairing()
        // Created now; the observer has not told the coordinator yet.
        let run = BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: [DeviceCoordinatorHarness.credentialName],
                                       callerName: "Synthetic Agent")
        guard case .approvalRequired = try harness.vault.brokerTextCredentials(for: run, cancellation: .init()) else {
            return XCTFail("a pending read")
        }
        let pending = try XCTUnwrap(harness.vault.approvalRequests.pendingRequests().last)
        XCTAssertNil(harness.coordinator.remoteRequests[pending.requestID])
        try await harness.phone.confirm()
        await harness.coordinator.refresh()
        XCTAssertNotNil(try harness.generation(of: harness.phone), "the iPhone joined")
        XCTAssertEqual(harness.coordinator.remoteRequests[pending.requestID]?.phase, .stayingOnMac)
        harness.coordinator.approvalRequestsChanged()
        await harness.coordinator.remoteApprovalTick()
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty)
    }

    func testAnEligibleRequestStillWaitingReachesANewlyPairedIPhoneAtItsMark() async throws {
        try await harness.pairApprover()
        harness.script.screenUnlocked = true
        let pending = try harness.submitRead()
        let second = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.pair(second, name: "Synthetic Phone Two")
        XCTAssertTrue(harness.macSent(.approvalRequest).isEmpty, "it waits for its 20-second mark")
        harness.clock.advance(by: 20)
        await harness.coordinator.remoteApprovalTick()
        try await harness.waitForRequests(2)
        XCTAssertEqual(Set(harness.entries(pending).map(\.approverID)), [harness.phone.deviceID, second.deviceID])
    }

    func testARetiredApproverConfirmationIsRefusedAsAnUnexpectedKind() async throws {
        try await harness.pairApprover()
        let generation = try harness.generation(of: harness.phone)
        try await harness.phone.sendRetiredApproverConfirmation(to: XCTUnwrap(harness.macDeviceID))
        await harness.coordinator.refresh()
        XCTAssertTrue(harness.refusals.contains(.unexpectedKind))
        XCTAssertEqual(try harness.generation(of: harness.phone), generation, "nothing changed")
        XCTAssertEqual(harness.coordinator.devices.map(\.isApprover), [true])
    }
}
