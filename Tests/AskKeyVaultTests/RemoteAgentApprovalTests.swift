import AskKeyBroker
import AskKeyDevices
import Foundation
import XCTest
@testable import AskKeyVault

/// The Vault's remote decision entry without the approval flag, and the
/// access record's device field (ADR 0014). Every value is synthetic.
final class RemoteAgentApprovalTests: RemoteApprovalVaultTestCase {
    func testRemoteDenySkipsTheListAndPolicyAndRecordsTheDevice() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        // The flag is off and the list cannot even be read: a Deny needs neither.
        library.keys.deviceItemFailure = SyntheticPolicyFailure()
        var policyReads = 0
        library.keys.onPolicyLoad = { policyReads += 1 }
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .deny),
                       .applied(.denied, grantedSeconds: 0))
        XCTAssertEqual(policyReads, 0, "A Deny never waits for policy I/O")
        library.keys.onPolicyLoad = nil
        let record = try XCTUnwrap(runtimeReadRecords(library.vault).last)
        XCTAssertEqual(record.result, .denied)
        XCTAssertEqual(record.deviceName, "Synthetic Phone")
    }

    func testRemoteDenyFromAnApproverOutsideTheSetIsRefused() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        library.vault.approvalRequests.removeActiveApprover(pairingID: device.pairingID.rawValue)
        XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, .deny), .approverInactive)
        XCTAssertEqual(try state(library.vault, pending), .pending)
    }

    func testRemoteAllowWithoutTheApprovalFlagIsRefusedAndLeavesTheRequestPending() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        let stranger = try syntheticDevice(name: "Not Paired")
        let generation = try activate(device, in: library.vault)
        let strangerGeneration = try activate(stranger, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        for code in [BrokerRemoteDecisionCode.allowOnce, .timedAllowance] {
            let ceiling: TimeInterval = code == .timedAllowance ? 600 : 0
            XCTAssertEqual(try decide(library.vault, pending, by: device, generation: generation, code, ceiling: ceiling),
                           .approverInactive)
            XCTAssertEqual(try decide(library.vault, pending, by: stranger, generation: strangerGeneration, code,
                                      ceiling: ceiling), .approverInactive)
        }
        XCTAssertEqual(try state(library.vault, pending), .pending)
        XCTAssertTrue(library.vault.approvalRequests.activeTimedAllowances().isEmpty)
    }

    func testRemoteAllowThatCannotReadTheListChangesNothing() async throws {
        let library = try makeLibrary()
        let device = try syntheticDevice()
        try await pair(device, in: library)
        let generation = try activate(device, in: library.vault)
        let pending = try pendingRead(in: library.vault)
        library.keys.deviceItemFailure = SyntheticPolicyFailure()
        XCTAssertThrowsError(try decide(library.vault, pending, by: device, generation: generation, .allowOnce))
        XCTAssertEqual(try state(library.vault, pending), .pending)
    }

    func testRecordsWrittenBeforeTheDeviceFieldDecodeUnchanged() throws {
        let legacy = LegacyAccessEvent(timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000.5), credentialID: "synthetic",
                                       operation: "runtimeRead", result: "allowed", callerHint: "Synthetic Agent",
                                       declaredPurpose: "synthetic purpose", executableBasename: "deploy.sh")
        let bytes = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CredentialAccessEvent.self, from: bytes)
        XCTAssertEqual(decoded, CredentialAccessEvent(timestamp: legacy.timestamp, credentialID: "synthetic",
                                                      operation: .runtimeRead, result: .allowed,
                                                      callerHint: "Synthetic Agent", declaredPurpose: "synthetic purpose",
                                                      executableBasename: "deploy.sh"))
        XCTAssertNil(decoded.deviceName)
        // A record decided on this Mac still encodes with the earlier keys only.
        let local = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertEqual(Set(try XCTUnwrap(local).keys), Set(try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]).keys))
        let remote = CredentialAccessEvent(timestamp: legacy.timestamp, credentialID: "synthetic", operation: .runtimeRead,
                                           result: .denied, callerHint: nil, declaredPurpose: nil, deviceName: "Synthetic Phone")
        XCTAssertEqual(try JSONDecoder().decode(CredentialAccessEvent.self, from: JSONEncoder().encode(remote)), remote)
    }

    func testStoredRecordsWithoutTheDeviceFieldStillList() throws {
        let library = try makeLibrary()
        let legacy = LegacyAccessEvent(timestamp: Date(), credentialID: "synthetic", operation: "catalog", result: "allowed",
                                       callerHint: nil, declaredPurpose: nil, executableBasename: nil)
        try library.store.insertCredentialAccessRecord(
            .init(id: UUID().uuidString, encryptedRecord: try VaultCrypto.encrypt(JSONEncoder().encode(legacy),
                                                                                  using: try library.key)),
            capacity: CredentialAccessRecordPolicy.maximumEntries)
        let records = try library.vault.listCredentialAccessRecords()
        XCTAssertEqual(records.map(\.credentialID), ["synthetic"])
        XCTAssertNil(records.first?.deviceName)
    }
}

/// The access record's encoding before ADR 0014 added the device field.
private struct LegacyAccessEvent: Codable {
    let timestamp: Date
    let credentialID: String?
    let operation: String
    let result: String
    let callerHint: String?
    let declaredPurpose: String?
    let executableBasename: String?
}
