@testable import AskKeyBroker
@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import Foundation
import XCTest
@testable import AskKeyVault

/// The approval flag's write rule on the Mac and the remote entry with the
/// flag on (ADR 0014 → Approvers, Vault entry; #336). Every value is synthetic.
final class DeviceApproverFlagTests: RemoteApprovalVaultTestCase {
    /// The entry a pairing adds for an iPhone: the pairing session sets the
    /// flag; tests reach it through `@testable` access only.
    private func flagged(_ device: PairedDevice) -> PairedDevice {
        var entry = device
        entry.isApprover = true
        return entry
    }

    /// Pairs the device as a pairing of this Mac with an iPhone does: the
    /// add that the pairing authorization allows carries the flag.
    private func pairApprover(_ device: PairedDevice, in library: AgentAccessPolicyLibrary) async throws {
        try await pair(flagged(device), in: library)
    }

    /// `list` with `entry` in place of the entry with its device ID, flag
    /// as given, as a write that bypasses the pairing session would hold it.
    private func list(_ list: PairedDeviceList, replacing entry: PairedDevice) throws -> PairedDeviceList {
        var changed = list
        try changed.apply(.add(entry))
        return changed
    }

    /// An identity with this message key, so with its device ID, and new
    /// agreement and approval keys.
    private func sameDeviceID(as messageKey: P256.Signing.PrivateKey) -> SoftwareDeviceIdentity {
        SoftwareDeviceIdentity(messageKey: messageKey, agreementKey: .init(), approvalKey: .init())
    }

    /// An entry under the pairing ID made of `byte`, with a card that
    /// `identity` signed at `seconds`.
    private func entry(_ identity: SoftwareDeviceIdentity, platform: DevicePlatform = .iOS,
                       signedAt seconds: TimeInterval = 1_800_000_000, pairingID byte: UInt8) throws -> PairedDevice {
        let card = try DeviceCard.make(identity: identity, platform: platform, createdAt: Date(timeIntervalSince1970: seconds))
        return PairedDevice(card: card, pairingID: try XCTUnwrap(PairingID(rawValue: Data(repeating: byte, count: 16))),
                            displayName: "Synthetic Phone", pairedAt: Date(timeIntervalSince1970: seconds + 100))
    }

    private func isApprover(_ device: PairedDevice, in library: AgentAccessPolicyLibrary) async throws -> Bool {
        try await library.vault.pairedDeviceRegistry().list().device(device.deviceID)?.isApprover == true
    }

    private func syntheticMac() throws -> PairedDevice {
        let card = try DeviceCard.make(identity: SoftwareDeviceIdentity(), platform: .macOS,
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let pairingID = try XCTUnwrap(PairingID(rawValue: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })))
        return PairedDevice(card: card, pairingID: pairingID, displayName: "Synthetic Mac",
                            pairedAt: Date(timeIntervalSince1970: 1_800_000_100))
    }

    private func assertRefused(_ expected: DeviceStorageError, _ library: AgentAccessPolicyLibrary, _ message: String,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ write: () async throws -> Void) async {
        let stored = library.keys.deviceItems[.pairedDevices]
        do {
            try await write()
            XCTFail(message, file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, expected, message, file: file, line: line)
        }
        XCTAssertEqual(library.keys.deviceItems[.pairedDevices], stored, "Nothing is written: \(message)", file: file, line: line)
    }

    // MARK: Write rule

    func testAnAddThatPairingAuthorizedMayCarryTheFlagForAnIPhone() async throws {
        let library = try makeLibrary()
        let phone = try syntheticDevice()
        let unflagged = try syntheticDevice(name: "Unflagged Phone")
        try await pairApprover(phone, in: library)
        try await pair(unflagged, in: library)
        let phoneFlag = try await isApprover(phone, in: library)
        let otherFlag = try await isApprover(unflagged, in: library)
        XCTAssertTrue(phoneFlag, "the flag is written in the add itself")
        XCTAssertFalse(otherFlag, "an add without the flag stays without it")
    }

    func testAFlagOnAnAddOfAnotherPlatformIsRefused() async throws {
        let library = try makeLibrary()
        let mac = try syntheticMac()
        await assertRefused(.approverNotAuthorized, library, "only an iOS card may carry the flag") {
            try await self.pairApprover(mac, in: library)
        }
        try await pair(mac, in: library)
        let flag = try await isApprover(mac, in: library)
        XCTAssertFalse(flag, "a Mac pairs without the flag")
    }

    func testAFlaggedAddStillNeedsThePairingAuthorizationAndTheManagementSession() async throws {
        let library = try makeLibrary()
        let phone = try syntheticDevice()
        let other = try syntheticDevice(name: "Other Phone")
        await assertRefused(.pairingNotAuthorized, library, "no pairing authorization") {
            try await library.vault.pairedDeviceRegistry().apply(.add(self.flagged(phone)))
        }
        try library.vault.authorizeDevicePairing(with: other.deviceID, using: .allow)
        await assertRefused(.pairingNotAuthorized, library, "the authorization is for another device") {
            try await library.vault.pairedDeviceRegistry().apply(.add(self.flagged(phone)))
        }
        try library.vault.authorizeDevicePairing(with: phone.deviceID, using: .allow)
        library.vault.endManagementSession()
        let stored = library.keys.deviceItems[.pairedDevices]
        do {
            try await library.vault.pairedDeviceRegistry().apply(.add(flagged(phone)))
            XCTFail("An add needs the management session")
        } catch {}
        XCTAssertEqual(library.keys.deviceItems[.pairedDevices], stored)
    }

    func testNoWriteChangesTheFlagOfAStoredEntry() async throws {
        let library = try makeLibrary()
        let phone = try syntheticDevice()
        let unflagged = try syntheticDevice(name: "Unflagged Phone")
        try await pairApprover(phone, in: library)
        try await pair(unflagged, in: library)
        let registry = try library.vault.pairedDeviceRegistry()
        let stored = try await registry.list()
        let epoch = library.vault.deviceState.currentEpoch
        await assertRefused(.approverNotAuthorized, library, "a list written directly turning a stored flag off") {
            try library.vault.savePairedDevices(try self.list(stored, replacing: phone), epoch: epoch)
        }
        await assertRefused(.approverNotAuthorized, library, "a list written directly turning a stored entry's flag on") {
            try library.vault.savePairedDevices(try self.list(stored, replacing: self.flagged(unflagged)), epoch: epoch)
        }
        // A fresh pairing authorization for the device does not cover its stored entry.
        try library.vault.authorizeDevicePairing(with: unflagged.deviceID, using: .allow)
        await assertRefused(.approverNotAuthorized, library, "adding the stored entry again with the flag") {
            try await registry.apply(.add(self.flagged(unflagged)))
        }
        await assertRefused(.approverNotAuthorized, library, "adding the stored entry again without the flag") {
            try await registry.apply(.add(phone))
        }
        await assertRefused(.approverNotAuthorized, library, "the same list written directly under that authorization") {
            try library.vault.savePairedDevices(try self.list(stored, replacing: self.flagged(unflagged)), epoch: epoch)
        }
        let phoneFlag = try await isApprover(phone, in: library)
        let otherFlag = try await isApprover(unflagged, in: library)
        XCTAssertTrue(phoneFlag)
        XCTAssertFalse(otherFlag)
    }

    func testAWriteCannotSwapTheCardOfAFlaggedEntry() async throws {
        let library = try makeLibrary()
        let messageKey = P256.Signing.PrivateKey()
        let identity = sameDeviceID(as: messageKey)
        let phone = try entry(identity, pairingID: 0x3C)
        try await pairApprover(phone, in: library)
        let generation = try activate(phone, in: library.vault)
        // Same device ID and pairing ID, flag kept, another card. The iOS
        // cards used to be adds, which the pairing authorization let through
        // while the Broker kept the pairing's generation; the Mac card failed
        // only the platform check.
        let swaps = [("another approval key", try entry(sameDeviceID(as: messageKey), pairingID: 0x3C)),
                     ("a newer card", try entry(identity, signedAt: 1_800_000_600, pairingID: 0x3C)),
                     ("a Mac card", try entry(identity, platform: .macOS, pairingID: 0x3C))]
        let registry = try library.vault.pairedDeviceRegistry()
        let epoch = library.vault.deviceState.currentEpoch
        for (name, swap) in swaps {
            XCTAssertEqual(swap.deviceID, phone.deviceID, name)
            XCTAssertNotEqual(swap.card, phone.card, name)
            library.vault.endDevicePairingAuthorization()
            await assertRefused(.pairingNotAuthorized, library, "\(name) without the pairing authorization") {
                try await registry.apply(.add(self.flagged(swap)))
            }
            try library.vault.authorizeDevicePairing(with: phone.deviceID, using: .allow)
            await assertRefused(.pairingNotAuthorized, library, "\(name) under the pairing authorization") {
                try await registry.apply(.add(self.flagged(swap)))
            }
            let stored = try await registry.list()
            await assertRefused(.pairingNotAuthorized, library, "\(name) in a list written directly") {
                try library.vault.savePairedDevices(try self.list(stored, replacing: self.flagged(swap)), epoch: epoch)
            }
        }
        // Another device cannot take the stored pairing ID either.
        let other = try entry(SoftwareDeviceIdentity(), pairingID: 0x3C)
        try library.vault.authorizeDevicePairing(with: other.deviceID, using: .allow)
        await assertRefused(.pairingNotAuthorized, library, "another device under the stored pairing ID") {
            try await registry.apply(.add(self.flagged(other)))
        }
        // A swap refuses the whole write, even beside the add the pairing
        // authorization covers, and leaves that authorization for the add.
        let tablet = try entry(SoftwareDeviceIdentity(), pairingID: 0x4D)
        try library.vault.authorizeDevicePairing(with: tablet.deviceID, using: .allow)
        let before = try await registry.list()
        let swap = flagged(try entry(sameDeviceID(as: messageKey), pairingID: 0x3C))
        await assertRefused(.pairingNotAuthorized, library, "a swap written with an authorized add") {
            var list = try self.list(before, replacing: swap)
            try list.apply(.add(self.flagged(tablet)))
            try library.vault.savePairedDevices(list, epoch: epoch)
        }
        try await registry.apply(.add(flagged(tablet)))
        let stored = try await registry.list().devices
        XCTAssertEqual(stored, [flagged(phone), flagged(tablet)])
        XCTAssertEqual(library.vault.approvalRequests.activeApproverGeneration(pairingID: phone.pairingID.rawValue), generation,
                       "the pairing keeps its authority with the card it was granted for")
    }

    /// A list that an earlier build stored with one pairing ID on two
    /// devices stays writable: each entry is checked against its own stored
    /// entry, and no third device joins that pairing ID.
    func testAStoredListWithASharedPairingIDCanStillBeRenamedAndEmptied() async throws {
        let library = try makeLibrary()
        let first = flagged(try entry(SoftwareDeviceIdentity(), pairingID: 0x3C))
        let second = try entry(SoftwareDeviceIdentity(), pairingID: 0x3C)
        library.keys.deviceItems[.pairedDevices] = try PairedDeviceListAuthentication.seal(
            try PairedDeviceList(devices: [first, second]), using: library.key)
        _ = try activate(first, in: library.vault)
        let registry = try library.vault.pairedDeviceRegistry()
        let third = try entry(SoftwareDeviceIdentity(), pairingID: 0x3C)
        try library.vault.authorizeDevicePairing(with: third.deviceID, using: .allow)
        await assertRefused(.pairingNotAuthorized, library, "a third device under the shared pairing ID") {
            try await registry.apply(.add(third))
        }
        await assertRefused(.approverNotAuthorized, library, "the second entry's flag turned on") {
            try await registry.apply(.add(self.flagged(second)))
        }
        library.vault.endManagementSession()
        try await registry.apply(.rename(second.deviceID, pairingID: second.pairingID, displayName: "Renamed Phone"))
        try await registry.apply(.remove(first.deviceID, pairingID: first.pairingID))
        XCTAssertNil(library.vault.approvalRequests.activeApproverGeneration(pairingID: first.pairingID.rawValue),
                     "removing the flagged entry ends the pairing ID's authority")
        let remaining = try await registry.list().devices
        XCTAssertEqual(remaining.map(\.deviceID), [second.deviceID])
        XCTAssertEqual(remaining.first?.displayName, "Renamed Phone")
        try await registry.apply(.remove(second.deviceID, pairingID: second.pairingID))
        let empty = try await registry.list().devices
        XCTAssertTrue(empty.isEmpty)
    }

    func testACardSwapCannotChangeTheFlag() async throws {
        let library = try makeLibrary()
        let phoneKey = P256.Signing.PrivateKey()
        let otherKey = P256.Signing.PrivateKey()
        let phone = try entry(sameDeviceID(as: phoneKey), pairingID: 0x3C)
        let unflagged = try entry(sameDeviceID(as: otherKey), pairingID: 0x4D)
        try await pairApprover(phone, in: library)
        try await pair(unflagged, in: library)
        let generation = try activate(phone, in: library.vault)
        let registry = try library.vault.pairedDeviceRegistry()
        // Under the device's pairing authorization, which used to make a card swap an add with any flag.
        try library.vault.authorizeDevicePairing(with: unflagged.deviceID, using: .allow)
        let flaggedSwap = flagged(try entry(sameDeviceID(as: otherKey), pairingID: 0x4D))
        await assertRefused(.approverNotAuthorized, library, "a stored entry's flag turned on with another iOS card") {
            try await registry.apply(.add(flaggedSwap))
        }
        try library.vault.authorizeDevicePairing(with: phone.deviceID, using: .allow)
        let unflaggedSwap = try entry(sameDeviceID(as: phoneKey), pairingID: 0x3C)
        await assertRefused(.approverNotAuthorized, library, "a stored flag turned off with another card") {
            try await registry.apply(.add(unflaggedSwap))
        }
        let phoneFlag = try await isApprover(phone, in: library)
        let otherFlag = try await isApprover(unflagged, in: library)
        XCTAssertTrue(phoneFlag)
        XCTAssertFalse(otherFlag)
        XCTAssertTrue(try library.vault.activateStoredApprovers(only: unflagged.pairingID).isEmpty,
                      "the unflagged pairing never joins the set")
        XCTAssertEqual(library.vault.approvalRequests.activeApproverGeneration(pairingID: phone.pairingID.rawValue), generation)
    }

    func testOtherChangesToAnApproverNeedNoAuthorization() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pairApprover(device, in: library)
        library.vault.endManagementSession()
        // A delivery check runs in the background, without the management session.
        try await library.vault.pairedDeviceRegistry().apply(.recordReached(device.deviceID, pairingID: device.pairingID,
                                                                            at: Date(timeIntervalSince1970: 1_800_000_200)))
        let entry = try await library.vault.pairedDeviceRegistry().list().device(device.deviceID)
        XCTAssertEqual(entry?.isApprover, true)
        XCTAssertNotNil(entry?.lastReachedAt)
    }

    func testActivatingStoredApproversAddsFlaggedEntriesWithNewGenerations() async throws {
        let library = try makeLibrary()
        let phone = try syntheticDevice()
        let tablet = try syntheticDevice(name: "Synthetic Tablet")
        let unflagged = try syntheticDevice(name: "Unflagged Phone")
        try await pairApprover(phone, in: library)
        try await pair(unflagged, in: library)
        let approvals = library.vault.approvalRequests
        let first = try library.vault.activateStoredApprovers()
        XCTAssertEqual(Set(first.keys), [phone.pairingID])
        try await pairApprover(tablet, in: library)
        // After the tablet's pairing, only the tablet is added; the phone keeps its generation.
        let added = try library.vault.activateStoredApprovers(only: tablet.pairingID)
        XCTAssertEqual(Set(added.keys), [tablet.pairingID])
        XCTAssertEqual(approvals.activeApproverGeneration(pairingID: phone.pairingID.rawValue), first[phone.pairingID])
        XCTAssertNil(approvals.activeApproverGeneration(pairingID: unflagged.pairingID.rawValue))
        XCTAssertTrue(try library.vault.activateStoredApprovers(only: unflagged.pairingID).isEmpty)
        // When the device services become ready again, every flagged entry gets a new generation.
        approvals.removeAllActiveApprovers()
        let reloaded = try library.vault.activateStoredApprovers()
        XCTAssertEqual(Set(reloaded.keys), [phone.pairingID, tablet.pairingID])
        XCTAssertGreaterThan(try XCTUnwrap(reloaded[phone.pairingID]), try XCTUnwrap(added[tablet.pairingID]))
    }

    // MARK: Revocation reaches the Broker first

    func testRemovingOrReplacingAnApproverEndsItsBrokerAuthority() async throws {
        for change in ["remove", "replace"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pairApprover(device, in: library)
            _ = try activate(device, in: library.vault)
            let before = library.vault.approvalRequests.activeApproverRevocationCount()
            if change == "remove" {
                try await library.vault.pairedDeviceRegistry().apply(.remove(device.deviceID, pairingID: device.pairingID))
            } else {
                // Pairing again gives the same device a new entry and pairing ID.
                let again = PairedDevice(card: device.card, pairingID: try XCTUnwrap(PairingID(rawValue: Data(repeating: 0x5C, count: 16))),
                                         displayName: device.displayName, pairedAt: device.pairedAt)
                try await pairApprover(again, in: library)
            }
            XCTAssertNil(library.vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue), change)
            XCTAssertGreaterThan(library.vault.approvalRequests.activeApproverRevocationCount(), before, change)
        }
    }

    /// A device's card changes only by pairing again, under a new pairing ID:
    /// the old pairing leaves the Broker's set and the new entry is flagged.
    func testPairingAgainWithANewCardEndsTheOldAuthorityAndFlagsTheNewEntry() async throws {
        for start in ["flagged", "unflagged"] {
            let library = try makeLibrary()
            let approvals = library.vault.approvalRequests
            let messageKey = P256.Signing.PrivateKey()
            let phone = try entry(sameDeviceID(as: messageKey), pairingID: 0x3C)
            if start == "flagged" { try await pairApprover(phone, in: library) } else { try await pair(phone, in: library) }
            let old = start == "flagged" ? try activate(phone, in: library.vault) : nil
            let before = approvals.activeApproverRevocationCount()
            let again = try entry(sameDeviceID(as: messageKey), signedAt: 1_800_000_600, pairingID: 0x5C)
            try await pairApprover(again, in: library)
            let stored = try await library.vault.pairedDeviceRegistry().list().devices
            XCTAssertEqual(stored, [flagged(again)], start)
            XCTAssertNil(approvals.activeApproverGeneration(pairingID: phone.pairingID.rawValue), start)
            if old != nil {
                XCTAssertGreaterThan(approvals.activeApproverRevocationCount(), before, "the old pairing left the set first")
            }
            let added = try library.vault.activateStoredApprovers(only: again.pairingID)
            XCTAssertEqual(Set(added.keys), [again.pairingID], start)
            if let old { XCTAssertGreaterThan(try XCTUnwrap(added[again.pairingID]), old, start) }
        }
    }

    func testARefusedWriteLeavesTheBrokerSetAlone() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pairApprover(device, in: library)
        let generation = try activate(device, in: library.vault)
        do {
            // The stored entry again without its flag.
            try await library.vault.pairedDeviceRegistry().apply(.add(device))
            XCTFail("A stored flag never changes")
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, .approverNotAuthorized)
        }
        XCTAssertEqual(library.vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue), generation)
    }

    func testIdentityResetAndLocalEraseEmptyTheBrokerSet() async throws {
        for path in ["reset", "erase"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pairApprover(device, in: library)
            _ = try activate(device, in: library.vault)
            if path == "reset" { try library.vault.resetDeviceIdentity() } else { library.vault.stopDeviceServicesForLocalErase() }
            XCTAssertNil(library.vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue), path)
        }
    }

    // MARK: Remote entry with the flag

    func testRemoteAllowOnceFromAFlaggedApproverApprovesAndRecordsTheDevice() async throws {
        let library = try makeLibrary()
        library.vault.approvalRequests.configureAuthentication { _ in
            XCTFail("A remote decision never calls the local authentication")
            return false
        }
        let device = try syntheticDevice()
        try await pairApprover(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .allowOnce),
                       .applied(.approved, grantedSeconds: 0))
        guard case let .resolved(_, _, lease) = try library.vault.brokerTextCredentials(for: pending.run,
                                                                                       cancellation: .init()) else {
            return XCTFail("The approved run resolves")
        }
        lease?.finish(); lease?.cleanup()
        let record = try XCTUnwrap(runtimeReadRecords(library.vault).last)
        XCTAssertEqual(record.result, .allowed)
        XCTAssertEqual(record.deviceName, "Synthetic Phone")
    }

    func testRemoteTimedGrantIsCappedAtTheSettingAndNamesTheDeviceForLaterReads() async throws {
        let library = try makeLibrary()
        try library.vault.updateTimedAllowance(enabled: true, minutes: 15)
        let device = try syntheticDevice()
        try await pairApprover(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .timedAllowance, ceiling: 7_200),
                       .applied(.approved, grantedSeconds: 900))
        for run in [pending.run, BrokerTextRunRequest(command: ["/usr/bin/true"], credentialNames: ["ASK"])] {
            guard case let .resolved(_, _, lease) = try library.vault.brokerTextCredentials(for: run, cancellation: .init()) else {
                return XCTFail("Covered by the remote allowance")
            }
            lease?.finish(); lease?.cleanup()
        }
        let records = try runtimeReadRecords(library.vault).suffix(2)
        XCTAssertEqual(records.map(\.deviceName), ["Synthetic Phone", "Synthetic Phone"])
        XCTAssertEqual(library.vault.approvalRequests.activeTimedAllowances().first?.approvingDeviceName, "Synthetic Phone")
    }

    func testCeilingThatIsNotAsSignedIsRefusedRatherThanCappedByTheSetting() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pairApprover(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        for ceiling in [7_201, 0, -1, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .timedAllowance,
                                      ceiling: ceiling), .notApplicable, "\(ceiling)")
        }
        XCTAssertEqual(try state(library.vault, pending), .pending)
        XCTAssertTrue(library.vault.approvalRequests.activeTimedAllowances().isEmpty)
    }

    func testAnEntryWithoutTheFlagIsRefusedEvenWhileTheBrokerListsItsPairing() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        // Paired before #336 without approval, yet somehow in the set.
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .allowOnce), .approverInactive)
        XCTAssertEqual(try state(library.vault, pending), .pending)
    }

    /// A policy change in another process reaches this one only through the
    /// revalidation a local decision also runs.
    func testRemoteAllowRevalidatesAPolicyChangedInAnotherProcess() async throws {
        for change in ["pause", "timed off", "end on lock"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pairApprover(device, in: library)
            let second = try makeSecondVault(library)
            let generation = try activate(device, in: second)
            let pending = try pendingRead(in: second)
            switch change {
            case "pause": try library.vault.pauseAgentAccess(using: .allow)
            case "timed off": try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
            default: try library.vault.updateEndTimedAllowancesOnLock(true, using: .allow)
            }
            XCTAssertFalse(second.approvalRequests.endTimedAllowancesOnLock, "Not adopted before the decision")
            let outcome = try? decide(second, pending, by: device, generation: generation, .timedAllowance, ceiling: 600)
            switch change {
            case "pause":
                XCTAssertNil(outcome, "Paused access refuses the decision")
                XCTAssertEqual(try state(second, pending), .cancelled)
            case "timed off":
                // A tightened delivery rule cancels pending requests, as for a local decision.
                XCTAssertEqual(outcome, .notPending(.cancelled, decidedBy: nil))
            default:
                XCTAssertEqual(outcome, .notApplicable, "End Timed Allow on Lock was adopted before the Broker check")
                XCTAssertEqual(try state(second, pending), .pending)
            }
            XCTAssertTrue(second.approvalRequests.activeTimedAllowances().isEmpty, change)
        }
    }

    func testRemoteAllowAfterTheCredentialChangedOrTimedAllowancesWereTurnedOffChangesNothing() async throws {
        for change in ["credential", "timed off"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pairApprover(device, in: library)
            let generation = try activate(device, in: library.vault)
            let pending = try pendingRead(in: library.vault)
            if change == "credential" {
                let id = try XCTUnwrap(library.store.fetchAllCredentials().first).id
                try library.vault.updateCredentialPermission(id: id, permission: .allowed, using: .allow)
                XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .allowOnce),
                               .notPending(.cancelled, decidedBy: nil))
            } else {
                try library.vault.updateTimedAllowance(enabled: false, minutes: 30)
                XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .timedAllowance,
                                          ceiling: 600), .notApplicable)
                XCTAssertEqual(try state(library.vault, pending), .pending)
            }
            XCTAssertTrue(library.vault.approvalRequests.activeTimedAllowances().isEmpty, change)
        }
    }
}
