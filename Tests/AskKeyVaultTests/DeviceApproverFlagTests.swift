@testable import AskKeyBroker
import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyVault

/// The approval flag's write rule on the Mac and the remote entry with the
/// flag on (ADR 0014 → Approvers, Vault entry). Every value is synthetic.
final class DeviceApproverFlagTests: RemoteApprovalVaultTestCase {
    private func enable(_ device: PairedDevice, in library: AgentAccessPolicyLibrary) async throws {
        try library.vault.authorizeDeviceApprover(device.deviceID, pairingID: device.pairingID, using: .allow)
        try await library.vault.pairedDeviceRegistry().apply(.setApprover(device.deviceID, pairingID: device.pairingID,
                                                                          enabled: true))
    }

    private func isApprover(_ device: PairedDevice, in library: AgentAccessPolicyLibrary) async throws -> Bool {
        try await library.vault.pairedDeviceRegistry().list().device(device.deviceID)?.isApprover == true
    }

    private func setApprover(_ device: PairedDevice, _ enabled: Bool, in library: AgentAccessPolicyLibrary) async throws {
        try await library.vault.pairedDeviceRegistry().apply(.setApprover(device.deviceID, pairingID: device.pairingID,
                                                                          enabled: enabled))
    }

    // MARK: Write rule

    func testTurningApprovalOnNeedsAMatchingAuthorizationAndWritesNothingOtherwise() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        let other = try syntheticDevice(name: "Other Phone")
        try await pair(device, in: library)
        try await pair(other, in: library)
        let stored = library.keys.deviceItems[.pairedDevices]
        let otherPairing = try XCTUnwrap(PairingID(rawValue: Data(repeating: 0x7A, count: 16)))
        let refusals: [(DeviceID, PairingID)?] = [nil, (other.deviceID, other.pairingID), (device.deviceID, otherPairing)]
        for authorization in refusals {
            library.vault.endDeviceApproverAuthorization()
            if let authorization {
                try library.vault.authorizeDeviceApprover(authorization.0, pairingID: authorization.1, using: .allow)
            }
            do {
                try await setApprover(device, true, in: library)
                XCTFail("Turning approval on needs the approver authorization for this device and pairing")
            } catch {
                XCTAssertEqual(error as? DeviceStorageError, .approverNotAuthorized)
            }
            XCTAssertEqual(library.keys.deviceItems[.pairedDevices], stored, "Nothing is written")
        }
        try await enable(device, in: library)
        let enabled = try await isApprover(device, in: library)
        XCTAssertTrue(enabled)
    }

    func testTurningApprovalOnNeedsTheManagementSession() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try library.vault.authorizeDeviceApprover(device.deviceID, pairingID: device.pairingID, using: .allow)
        library.vault.endManagementSession()
        let stored = library.keys.deviceItems[.pairedDevices]
        do {
            try await setApprover(device, true, in: library)
            XCTFail("Turning approval on needs the management session")
        } catch {}
        XCTAssertEqual(library.keys.deviceItems[.pairedDevices], stored)
        // The ended session also dropped the authorization.
        try library.vault.beginManagementSession(using: .allow)
        do {
            try await setApprover(device, true, in: library)
            XCTFail("The authorization ended with the session")
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, .approverNotAuthorized)
        }
    }

    func testTheWriteUsesTheAuthorizationUp() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try await enable(device, in: library)
        try await setApprover(device, false, in: library)
        do {
            try await setApprover(device, true, in: library)
            XCTFail("One authorization turns approval on once")
        } catch {
            XCTAssertEqual(error as? DeviceStorageError, .approverNotAuthorized)
        }
        let enabled = try await isApprover(device, in: library)
        XCTAssertFalse(enabled)
    }

    func testTurningApprovalOffNeedsOnlyTheManagementSession() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try await enable(device, in: library)
        library.vault.endManagementSession()
        do {
            try await setApprover(device, false, in: library)
            XCTFail("Turning approval off needs the management session")
        } catch {}
        var enabled = try await isApprover(device, in: library)
        XCTAssertTrue(enabled)
        try library.vault.beginManagementSession(using: .allow)
        try await setApprover(device, false, in: library)
        enabled = try await isApprover(device, in: library)
        XCTAssertFalse(enabled)
    }

    func testOneWriteCannotTurnOnTwoDevices() async throws {
        let library = try makeLibrary()
        let first = try syntheticDevice()
        let second = try syntheticDevice(name: "Second Phone")
        try await pair(first, in: library)
        try await pair(second, in: library)
        try library.vault.authorizeDeviceApprover(first.deviceID, pairingID: first.pairingID, using: .allow)
        var list = try await library.vault.pairedDeviceRegistry().list()
        try list.apply(.setApprover(first.deviceID, pairingID: first.pairingID, enabled: true))
        try list.apply(.setApprover(second.deviceID, pairingID: second.pairingID, enabled: true))
        XCTAssertThrowsError(try library.vault.savePairedDevices(list, epoch: library.vault.deviceState.currentEpoch)) {
            XCTAssertEqual($0 as? DeviceStorageError, .approverNotAuthorized)
        }
    }

    func testOtherChangesToAnApproverNeedNoAuthorization() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try await enable(device, in: library)
        library.vault.endManagementSession()
        // A delivery check runs in the background, without the management session.
        try await library.vault.pairedDeviceRegistry().apply(.recordReached(device.deviceID, pairingID: device.pairingID,
                                                                            at: Date(timeIntervalSince1970: 1_800_000_200)))
        let entry = try await library.vault.pairedDeviceRegistry().list().device(device.deviceID)
        XCTAssertEqual(entry?.isApprover, true)
        XCTAssertNotNil(entry?.lastReachedAt)
    }

    // MARK: Revocation reaches the Broker first

    func testTurningOffRemovingOrReplacingAnApproverEndsItsBrokerAuthority() async throws {
        for change in ["off", "remove", "replace"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pair(device, in: library)
            try await enable(device, in: library)
            _ = try activate(device, in: library.vault)
            let before = library.vault.approvalRequests.activeApproverRevocationCount()
            switch change {
            case "off": try await setApprover(device, false, in: library)
            case "remove":
                try await library.vault.pairedDeviceRegistry().apply(.remove(device.deviceID, pairingID: device.pairingID))
            default:
                // Pairing again gives the same device a new entry and pairing ID.
                let again = PairedDevice(card: device.card, pairingID: try XCTUnwrap(PairingID(rawValue: Data(repeating: 0x5C, count: 16))),
                                         displayName: device.displayName, pairedAt: device.pairedAt)
                try await pair(again, in: library)
            }
            XCTAssertNil(library.vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue), change)
            XCTAssertGreaterThan(library.vault.approvalRequests.activeApproverRevocationCount(), before, change)
        }
    }

    func testARefusedWriteLeavesTheBrokerSetAlone() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try await enable(device, in: library)
        let generation = try activate(device, in: library.vault)
        library.vault.endManagementSession()
        do {
            try await setApprover(device, false, in: library)
            XCTFail("Turning approval off needs the management session")
        } catch {}
        XCTAssertEqual(library.vault.approvalRequests.activeApproverGeneration(pairingID: device.pairingID.rawValue), generation)
    }

    func testIdentityResetAndLocalEraseEmptyTheBrokerSet() async throws {
        for path in ["reset", "erase"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pair(device, in: library)
            try await enable(device, in: library)
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
        try await pair(device, in: library)
        try await enable(device, in: library)
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
        try await pair(device, in: library)
        try await enable(device, in: library)
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
        try await pair(device, in: library)
        try await enable(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        for ceiling in [7_201, 0, -1, .infinity, .nan] as [TimeInterval] {
            XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .timedAllowance,
                                      ceiling: ceiling), .notApplicable, "\(ceiling)")
        }
        XCTAssertEqual(try state(library.vault, pending), .pending)
        XCTAssertTrue(library.vault.approvalRequests.activeTimedAllowances().isEmpty)
    }

    func testFlagTurnedOffIsRefusedEvenWhileTheBrokerStillListsTheApprover() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        try await enable(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        try await setApprover(device, false, in: library)
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .allowOnce), .approverInactive)
        XCTAssertEqual(try state(library.vault, pending), .pending)
    }

    /// A policy change in another process reaches this one only through the
    /// revalidation a local decision also runs.
    func testRemoteAllowRevalidatesAPolicyChangedInAnotherProcess() async throws {
        for change in ["pause", "timed off", "end on lock"] {
            let library = try makeLibrary()
            let device = try syntheticDevice()
            try await pair(device, in: library)
            try await enable(device, in: library)
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
            try await pair(device, in: library)
            try await enable(device, in: library)
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
