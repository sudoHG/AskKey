import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// Delivery checks, removal, the iCloud account, the unusable identity, push
/// hints and local erase in the Mac's device services (ADR 0013).
@MainActor
final class DeviceCoordinatorDevicesTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
    }

    func testMacThatNeverPairedMakesNoCloudKitRequest() async throws {
        await harness.coordinator.devicesOpened()
        await harness.coordinator.refresh()
        XCTAssertEqual(harness.backend.accountChecks, 0)
        XCTAssertTrue(harness.backend.preparedInboxes.isEmpty)
        XCTAssertTrue(harness.transport.sentEnvelopes.isEmpty)
        XCTAssertEqual(harness.coordinator.account, .unknown)
    }

    func testDeliveryCheckUpdatesLastReached() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        guard case .reached(let first) = try XCTUnwrap(coordinator.devices.first).reachability else {
            return XCTFail("the first delivery check reached the iPhone")
        }
        harness.clock.advance(by: 120)
        await coordinator.sendDeliveryCheck(to: harness.phone.deviceID)
        guard case .pending = try XCTUnwrap(coordinator.devices.first).lastDeliveryCheck else {
            return XCTFail("the check is pending until the reply")
        }
        try await harness.phone.poll()
        await coordinator.refresh()
        let row = try XCTUnwrap(coordinator.devices.first)
        guard case .replied = row.lastDeliveryCheck, case .reached(let latest) = row.reachability else {
            return XCTFail("the reply updates the device")
        }
        XCTAssertEqual(latest.timeIntervalSince(first), 120, accuracy: 1)
    }

    func testRemovalRefusesLaterMessagesAtOnceAndDeliversAnUnpairNotice() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        let mac = try XCTUnwrap(harness.macDeviceID)
        let outcome1 = await coordinator.removeDevice(harness.phone.deviceID)
        XCTAssertTrue(outcome1)
        XCTAssertTrue(coordinator.devices.isEmpty)
        XCTAssertEqual(harness.macSent(.unpairNotice).count, 1)

        // The iPhone still lists the Mac and sends before it reads the notice.
        try await harness.phone.messenger.sendDeliveryCheck(to: mac)
        await coordinator.refresh()
        XCTAssertTrue(harness.script.loggedEvents.contains(.messageRefused(.unknownSender)))
        XCTAssertTrue(coordinator.devices.isEmpty)

        try await harness.phone.poll()
        let phoneList = try await harness.phone.pairedDevices()
        XCTAssertTrue(phoneList.isEmpty, "the iPhone removed the Mac after the notice")
    }

    func testRemovalAndRenamingNeedTheManagementSession() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        let row = try XCTUnwrap(coordinator.devices.first)
        harness.script.managementActive = false
        let outcome2 = await coordinator.removeDevice(row.id)
        XCTAssertFalse(outcome2)
        let outcome3 = await coordinator.renameDevice(row, to: "Renamed")
        XCTAssertFalse(outcome3)
        XCTAssertEqual(coordinator.lastIssue, .managementRequired)
        XCTAssertEqual(coordinator.devices.map(\.displayName), ["Synthetic Phone"])
        harness.script.managementActive = true
        let outcome4 = await coordinator.renameDevice(row, to: "Renamed Phone")
        XCTAssertTrue(outcome4)
        XCTAssertEqual(coordinator.devices.map(\.displayName), ["Renamed Phone"])
    }

    func testListChangePreparedBeforeARemovalOrANewPairingDoesNotApply() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        let stale = try XCTUnwrap(coordinator.devices.first)
        let outcome5 = await coordinator.removeDevice(stale.id)
        XCTAssertTrue(outcome5)
        let outcome6 = await coordinator.renameDevice(stale, to: "Late Rename")
        XCTAssertFalse(outcome6)
        XCTAssertEqual(coordinator.lastIssue, .deviceNotFound)
        XCTAssertTrue(coordinator.devices.isEmpty, "the removed device is not restored")

        try await harness.phone.poll()
        try await harness.pairPhone()
        let current = try XCTUnwrap(coordinator.devices.first)
        XCTAssertNotEqual(current.pairingID, stale.pairingID)
        let outcome7 = await coordinator.renameDevice(stale, to: "Late Rename")
        XCTAssertFalse(outcome7)
        XCTAssertEqual(coordinator.devices.map(\.displayName), ["Synthetic Phone"])
    }

    func testAccountChangeMarksDevicesUnreachableAlsoWhenItHappenedWhileTheAppWasNotRunning() async throws {
        try await harness.pairPhone()
        guard case .reached = try XCTUnwrap(harness.coordinator.devices.first).reachability else {
            return XCTFail("reached before the change")
        }

        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await harness.coordinator.accountMayHaveChanged()
        XCTAssertEqual(harness.coordinator.account, .accountChanged)
        XCTAssertEqual(harness.coordinator.devices.map(\.reachability), [.unreachable])
        XCTAssertTrue(harness.script.loggedEvents.contains(.accountChanged))
        await harness.coordinator.startPairing()
        XCTAssertEqual(harness.coordinator.pairing, .failed(.accountUnavailable(.accountChanged)))

        // The App was not running when the account changed.
        await harness.relaunch()
        XCTAssertEqual(harness.coordinator.account, .accountChanged)
        XCTAssertEqual(harness.coordinator.devices.map(\.reachability), [.unreachable])
        XCTAssertEqual(harness.coordinator.devices.count, 1, "the list is kept")

        harness.backend.accountState = .noAccount
        await harness.coordinator.accountMayHaveChanged()
        XCTAssertEqual(harness.coordinator.account, .noAccount)
        XCTAssertEqual(harness.coordinator.devices.map(\.reachability), [.unreachable])

        // Signing back in to the account the devices were paired in.
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-1")
        await harness.relaunch()
        XCTAssertEqual(harness.coordinator.account, .available)
        guard case .reached = try XCTUnwrap(harness.coordinator.devices.first).reachability else {
            return XCTFail("reachable again in the original account")
        }
    }

    func testAccountChangeWithAnEmptyListAdoptsTheNewAccount() async throws {
        try await harness.pairPhone()
        let outcome8 = await harness.coordinator.removeDevice(harness.phone.deviceID)
        XCTAssertTrue(outcome8)
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await harness.coordinator.accountMayHaveChanged()
        XCTAssertEqual(harness.coordinator.account, .available)
        XCTAssertEqual(try harness.library.vault.loadDeviceInboxState().listAccount, "_synthetic-account-2")
    }

    func testPlantedKeyItemsAreRefusedAndOfferTheReset() async throws {
        try await harness.pairPhone()
        // Another App replaced a key item with a blob of its own.
        harness.library.keys.deviceItems[.messageKey] = try harness.backend.createIdentity().blobs.message
        await harness.relaunch()
        XCTAssertEqual(harness.coordinator.availability, .identityUnusable)
        XCTAssertFalse(harness.coordinator.hasIdentity)
        XCTAssertTrue(harness.backend.restoredIdentities.isEmpty, "the planted blob was never restored")
        let reset = await harness.coordinator.resetIdentity()
        XCTAssertTrue(reset)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty)
    }

    func testAnOlderAccountAnswerDoesNotOverwriteANewerAccountChange() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        let gate = AccountGate()
        let before = harness.backend.accountChecks
        harness.backend.accountAnswerGate = { await gate.wait() }
        let older = Task { await coordinator.accountMayHaveChanged() }
        let backend = harness.backend
        try await harness.waitUntil { backend.accountChecks > before }

        // The account changes while the older check is still out.
        harness.backend.accountAnswerGate = nil
        harness.backend.accountState = .available(userRecordName: "_synthetic-account-2")
        await coordinator.accountMayHaveChanged()
        XCTAssertEqual(coordinator.account, .accountChanged)

        gate.release()
        await older.value
        XCTAssertEqual(coordinator.account, .accountChanged, "the older answer describes the old account")
        XCTAssertEqual(coordinator.devices.map(\.reachability), [.unreachable])
    }

    func testUnusableIdentityAtLaunchOffersTheResetThatDeletesKeysAndList() async throws {
        try await harness.pairPhone()
        harness.backend.restoreFails = true
        await harness.relaunch()
        let coordinator = harness.coordinator
        XCTAssertEqual(coordinator.availability, .identityUnusable)
        await coordinator.startPairing()
        XCTAssertEqual(coordinator.pairing, .failed(.identityUnusable), "pairing waits for the reset")

        harness.script.managementActive = false
        let outcome9 = await coordinator.resetIdentity()
        XCTAssertFalse(outcome9)
        harness.script.managementActive = true
        let outcome10 = await coordinator.resetIdentity()
        XCTAssertTrue(outcome10)
        XCTAssertEqual(coordinator.availability, .ready)
        XCTAssertFalse(coordinator.hasIdentity)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty)

        harness.backend.restoreFails = false
        await coordinator.startPairing()
        guard case .showingQRCode = coordinator.pairing else { return XCTFail("a new identity can pair") }
        await coordinator.cancelPairing()
    }

    func testKeyThatStopsWorkingOffersTheResetWhichAlsoDeletesTheInbox() async throws {
        try await harness.pairPhone()
        await harness.relaunch()
        let mac = try XCTUnwrap(harness.macDeviceID)
        try XCTUnwrap(harness.backend.restoredIdentities.last).isUnusable = true
        try await harness.phone.messenger.sendDeliveryCheck(to: mac)
        await harness.coordinator.refresh()
        XCTAssertEqual(harness.coordinator.availability, .identityUnusable)
        XCTAssertTrue(harness.script.loggedEvents.contains(.identityUnusable))

        let outcome11 = await harness.coordinator.resetIdentity()
        XCTAssertTrue(outcome11)
        XCTAssertEqual(harness.backend.removedInboxes, [mac])
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty)
        XCTAssertEqual(try harness.library.vault.loadDeviceInboxState(), DeviceInboxState())
    }

    func testPushHintOnlyMakesTheMacFetchItsOwnInbox() async throws {
        try await harness.pairPhone()
        let mac = try XCTUnwrap(harness.macDeviceID)
        try await harness.phone.messenger.sendDeliveryCheck(to: mac)

        harness.coordinator.handleRemoteNotification(FakeDeviceServicesBackend.pushHint(for: harness.phone.deviceID))
        harness.coordinator.handleRemoteNotification(["aps": ["content-available": 1]])
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(harness.coordinator.pollTask, "no poll started")
        XCTAssertEqual(harness.transport.records(in: mac).count, 1, "a hint for another inbox does nothing")

        harness.coordinator.handleRemoteNotification(FakeDeviceServicesBackend.pushHint(for: mac))
        let transport = harness.transport
        try await harness.waitUntil { transport.records(in: mac).isEmpty }
        XCTAssertTrue(harness.transport.records(in: mac).isEmpty, "the hint made the Mac fetch and process")
    }

    func testLaunchProcessesIncomingMessagesAndKeepsTheInboxToken() async throws {
        try await harness.pairPhone()
        let mac = try XCTUnwrap(harness.macDeviceID)
        try await harness.phone.messenger.sendDeliveryCheck(to: mac)
        await harness.relaunch()
        XCTAssertTrue(harness.transport.records(in: mac).isEmpty, "launch processed the inbox")
        let state = try harness.library.vault.loadDeviceInboxState()
        XCTAssertNotNil(state.inboxToken)
        XCTAssertEqual(state.tokenAccount, "_synthetic-account-1")
        XCTAssertEqual(state.listAccount, "_synthetic-account-1")
        XCTAssertGreaterThanOrEqual(harness.backend.preparedInboxes.filter { $0 == mac }.count, 2,
                                    "each launch prepares the inbox in the current account")
    }

    func testLocalEraseStopsTheServicesAndDropsWhatTheyHeld() async throws {
        try await harness.pairPhone()
        let coordinator = harness.coordinator
        let mac = try XCTUnwrap(harness.macDeviceID)
        harness.library.vault.setDeviceServicesStopHandler {
            MainActor.assumeIsolated { coordinator.stopForLocalErase() }
        }
        _ = try await harness.startAndScan()

        try harness.library.vault.eraseLocalLibrary(confirmation: LocalVaultEraseLanguage.english.confirmationText,
                                                    language: .english, using: .allow)

        XCTAssertFalse(coordinator.hasIdentity)
        XCTAssertNil(coordinator.services)
        XCTAssertNil(coordinator.pairing)
        XCTAssertTrue(coordinator.devices.isEmpty)
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty)
        let backend = harness.backend
        try await harness.waitUntil { !backend.removedInboxes.isEmpty }
        XCTAssertEqual(harness.backend.removedInboxes, [mac], "the inbox is deleted on a best-effort basis")
    }
}


/// Holds account checks until the test releases them.
private final class AccountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuations = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        continuations.forEach { $0.resume() }
    }
}
