@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// The approval flag, list serialization version 2 (ADR 0014 → Approvers)
/// and the removal hook (ADR 0014 → Revocation; #310 acceptance 6).
final class ApprovalFlagTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ identity: SoftwareDeviceIdentity = SoftwareDeviceIdentity(), pairing: UInt8 = 1,
                       name: String = "Phone") throws -> PairedDevice {
        PairedDevice(card: try DeviceCard.make(identity: identity, platform: .iOS, createdAt: now),
                     pairingID: PairingID(rawValue: Data(repeating: pairing, count: 16))!, displayName: name, pairedAt: now)
    }

    func testTheFlagStartsOffAndOnlySetApproverChangesIt() throws {
        let device = try entry()
        XCTAssertFalse(device.isApprover)
        var list = try PairedDeviceList(devices: [device])
        XCTAssertEqual(try list.apply(.setApprover(device.deviceID, pairingID: device.pairingID, enabled: true)), .applied)
        XCTAssertTrue(list.devices[0].isApprover)
        let otherPairing = PairingID(rawValue: Data(repeating: 9, count: 16))!
        XCTAssertEqual(try list.apply(.setApprover(device.deviceID, pairingID: otherPairing, enabled: false)), .dropped,
                       "a change prepared against another pairing is dropped")
        XCTAssertTrue(list.devices[0].isApprover)
        XCTAssertEqual(try list.apply(.setApprover(device.deviceID, pairingID: device.pairingID, enabled: false)), .applied)
        XCTAssertFalse(list.devices[0].isApprover)
        XCTAssertEqual(try list.apply(.setApprover(SoftwareDeviceIdentity().deviceID, pairingID: device.pairingID,
                                                   enabled: true)), .dropped)
    }

    func testEveryListChangeKeepsTheFlagAndPairingAgainClearsIt() throws {
        let identity = SoftwareDeviceIdentity()
        let device = try entry(identity)
        let id = device.deviceID
        var list = try PairedDeviceList(devices: [device, try entry(pairing: 2, name: "Other")])
        try list.apply(.setApprover(id, pairingID: device.pairingID, enabled: true))
        let changes: [PairedDeviceChange] = [
            .rename(id, pairingID: device.pairingID, displayName: "Renamed"),
            .recordReached(id, pairingID: device.pairingID, at: now.addingTimeInterval(5)),
            .recordDeliveryCheck(id, pairingID: device.pairingID, result: .pending(sentAt: now.addingTimeInterval(6))),
            .recordDeliveryCheck(id, pairingID: device.pairingID, result: .noReply(sentAt: now.addingTimeInterval(6))),
            .recordDeliveryCheck(id, pairingID: device.pairingID, result: .replied(at: now.addingTimeInterval(7))),
            .add(device),
            .remove(list.devices[1].deviceID, pairingID: list.devices[1].pairingID),
        ]
        for change in changes {
            try list.apply(change)
            XCTAssertTrue(try XCTUnwrap(list.device(id)).isApprover, "\(change) keeps the flag")
        }
        var flagged = device
        flagged.isApprover = true
        try list.apply(.remove(id, pairingID: device.pairingID))
        try list.apply(.add(flagged))
        XCTAssertFalse(try XCTUnwrap(list.device(id)).isApprover, "a new entry starts with the flag off")
        try list.apply(.setApprover(id, pairingID: device.pairingID, enabled: true))
        try list.apply(.add(try entry(identity, pairing: 3)))
        XCTAssertFalse(try XCTUnwrap(list.device(id)).isApprover, "pairing again gives a new entry with the flag off")
    }

    func testSerializationVersionTwoCarriesTheFlag() throws {
        let first = try entry(name: "One")
        let second = try entry(pairing: 2, name: "Two")
        var list = try PairedDeviceList(devices: [first, second])
        try list.apply(.setApprover(second.deviceID, pairingID: second.pairingID, enabled: true))
        let data = try list.serialized()
        let decoded = try PairedDeviceList(serialized: data)
        XCTAssertEqual(decoded, list)
        XCTAssertEqual(decoded.devices.map(\.isApprover), [false, true])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        let entries = try XCTUnwrap(json["devices"] as? [[String: Any]])
        XCTAssertEqual(entries.map { $0["approver"] as? Bool }, [false, true])
        XCTAssertEqual(PairedDeviceList.serializationVersion, 2)
    }

    func testVersionOneDecodesWithEveryFlagOffAndVersionTwoRequiresIt() throws {
        var list = try PairedDeviceList(devices: [try entry(name: "One"), try entry(pairing: 2, name: "Two")])
        try list.apply(.setApprover(list.devices[0].deviceID, pairingID: list.devices[0].pairingID, enabled: true))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: try list.serialized()) as? [String: Any])
        var entries = try XCTUnwrap(json["devices"] as? [[String: Any]])

        json["version"] = 1
        json["devices"] = entries.map { var entry = $0; entry["approver"] = nil; return entry }
        let versionOne = try PairedDeviceList(serialized: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(versionOne.devices.map(\.isApprover), [false, false])
        XCTAssertEqual(versionOne.devices.map(\.displayName), ["One", "Two"])
        XCTAssertEqual(try PairedDeviceList(serialized: try versionOne.serialized()).devices.count, 2, "rewritten as version 2")
        XCTAssertTrue(String(decoding: try versionOne.serialized(), as: UTF8.self).contains("\"version\":2"))

        json["devices"] = entries
        let flaggedVersionOne = try PairedDeviceList(serialized: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(flaggedVersionOne.devices.map(\.isApprover), [false, false], "version 1 has no flags to read")

        json["version"] = 2
        entries[1]["approver"] = nil
        json["devices"] = entries
        XCTAssertThrowsError(try PairedDeviceList(serialized: try JSONSerialization.data(withJSONObject: json)),
                             "version 2 requires the key") { XCTAssertEqual($0 as? PairedDeviceListError, .malformed) }
        for wrong: Any in ["true", 1, NSNull()] {
            entries[1]["approver"] = wrong
            json["devices"] = entries
            XCTAssertThrowsError(try PairedDeviceList(serialized: try JSONSerialization.data(withJSONObject: json)),
                                 "approver \(wrong)") { XCTAssertEqual($0 as? PairedDeviceListError, .malformed) }
        }
    }

    // MARK: The removal hook

    func testTheHookRunsBeforeARemovalOnThisDeviceCommits() async throws {
        let fixture = try await ApprovalFixture.make()
        let entry = try await fixture.macEntryForPhone()
        try await fixture.mac.messenger.removeDevice(fixture.phone.id)
        XCTAssertEqual(fixture.removals.entries.map(\.pairingID), [entry.pairingID])
        XCTAssertEqual(fixture.removals.entries.first?.isApprover, true, "the hook sees the entry as it was")
        XCTAssertTrue(fixture.removals.allBeforeCommit)
        await XCTAssertNilAsync(try await fixture.mac.entry(for: fixture.phone))
    }

    func testTheHookRunsBeforeTheRemovalAnUnpairNoticeCausesCommits() async throws {
        let fixture = try await ApprovalFixture.make()
        let entry = try await fixture.macEntryForPhone()
        try await fixture.phone.messenger.removeDevice(fixture.mac.id)
        XCTAssertTrue(fixture.removals.entries.isEmpty)
        let report = try await fixture.mac.poll()
        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(fixture.removals.entries.map(\.deviceID), [entry.deviceID])
        XCTAssertEqual(fixture.removals.entries.map(\.pairingID), [entry.pairingID])
        XCTAssertTrue(fixture.removals.allBeforeCommit)
        await XCTAssertNilAsync(try await fixture.mac.entry(for: fixture.phone))
    }

    func testTheHookRunsBeforePairingAgainReplacesTheEntryAndBeforeAnUndo() async throws {
        let fixture = try await ApprovalFixture.make()
        let (mac, phone, harness) = (fixture.mac!, fixture.phone!, fixture.harness)
        let old = try await fixture.macEntryForPhone()
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        try await mac.confirm()
        try await phone.confirm()
        try await mac.poll()
        let new = try await fixture.macEntryForPhone()
        XCTAssertNotEqual(new.pairingID, old.pairingID)
        XCTAssertFalse(new.isApprover, "pairing again starts with approval off")
        XCTAssertEqual(fixture.removals.entries.map(\.pairingID), [old.pairingID], "the replaced entry was announced")
        XCTAssertTrue(fixture.removals.allBeforeCommit)

        // A QR holder withdraws within the new session, which undoes its result.
        let onlooker = harness.makeDevice(.iOS)
        try await onlooker.messenger.joinPairing(scannedText: qr.text, displayName: "Onlooker")
        await onlooker.messenger.cancelPairing()
        try await mac.poll()
        XCTAssertEqual(fixture.removals.entries.map(\.pairingID), [old.pairingID, new.pairingID])
        XCTAssertTrue(fixture.removals.allBeforeCommit)
        await XCTAssertNilAsync(try await mac.entry(for: phone))
    }

    func testTheHookRunsBeforeTheRollbackOfAnAddWhoseSessionEndedDuringTheWrite() async throws {
        let harness = DeviceHarness()
        let store = InMemoryPairedDeviceListStore()
        let log = RemovalLog()
        let record = log.hook(store: store)
        let canceller = Canceller()
        let mac = SimulatedDevice(identity: SoftwareDeviceIdentity(), store: store, platform: .macOS, harness: harness,
                                  options: .init(removalHook: { entry in
                                      await record(entry)
                                      await canceller.cancel(onRemovalOf: entry)
                                  }))
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        let old = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        canceller.arm(mac.messenger, cancellingOn: old.pairingID)

        // Pairing again; Cancel arrives while the replacing write waits for the hook.
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        try await mac.confirm()
        try await phone.confirm()
        try await mac.poll()

        XCTAssertEqual(log.entries.count, 2, "the replaced entry, then the rolled-back new one")
        XCTAssertEqual(log.entries.first?.pairingID, old.pairingID)
        XCTAssertNotEqual(log.entries.last?.pairingID, old.pairingID)
        XCTAssertTrue(log.allBeforeCommit)
        await XCTAssertNilAsync(try await mac.entry(for: phone), "the ended session stores nothing")
    }

    func testTheRegistryAnnouncesEveryEntryAWriteRemovesEvenWhenTheListChangesDuringTheHook() async throws {
        let identity = SoftwareDeviceIdentity()
        let first = try entry(identity, pairing: 1)
        let second = try entry(identity, pairing: 2)
        let third = try entry(identity, pairing: 3)
        let store = InMemoryPairedDeviceListStore(try PairedDeviceList(devices: [first]))
        let registry = PairedDeviceRegistry(store: store)
        let log = RemovalLog()
        let record = log.hook(store: store)
        let interfered = Interference()
        let outcome = try await registry.apply(.add(third)) { entry in
            await record(entry)
            // Another writer pairs again while the first hook runs.
            if interfered.once() { _ = try? await registry.apply(.add(second)) }
        }
        XCTAssertEqual(outcome, .applied)
        XCTAssertEqual(log.entries.map(\.pairingID), [first.pairingID, second.pairingID],
                       "the entry the write finally removed was announced too")
        XCTAssertTrue(log.allBeforeCommit)
        XCTAssertEqual(try store.loadPairedDeviceList().devices.map(\.pairingID), [third.pairingID])

        let dropped = try await registry.apply(.remove(identity.deviceID, pairingID: first.pairingID)) { _ in
            XCTFail("a dropped change removes nothing")
        }
        XCTAssertEqual(dropped, .dropped)
    }
}

private final class Interference: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}

/// Cancels the Mac's pairing session from inside the removal hook, once.
private final class Canceller: @unchecked Sendable {
    private let lock = NSLock()
    private var messenger: DeviceMessenger?
    private var pairingID: PairingID?

    func arm(_ messenger: DeviceMessenger, cancellingOn pairingID: PairingID) {
        lock.withLock {
            self.messenger = messenger
            self.pairingID = pairingID
        }
    }

    func cancel(onRemovalOf entry: PairedDevice) async {
        let target = lock.withLock { () -> DeviceMessenger? in
            guard entry.pairingID == pairingID else { return nil }
            pairingID = nil
            return messenger
        }
        await target?.cancelPairing()
    }
}
