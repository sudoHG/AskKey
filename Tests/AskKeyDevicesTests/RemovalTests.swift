import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

final class RemovalTests: XCTestCase {
    func testRemovalTakesEffectAtOnceAndOnThePeerAfterItProcessesTheNotice() async throws {
        for removerIsMac in [true, false] {
            let harness = DeviceHarness()
            let mac = harness.makeDevice(.macOS)
            let phone = harness.makeDevice(.iOS)
            try await harness.pair(mac, phone)
            let (remover, peer) = removerIsMac ? (mac, phone) : (phone, mac)

            let noticeSent = try await remover.messenger.removeDevice(peer.id)
            XCTAssertTrue(noticeSent)
            let removerEntry = try await remover.entry(for: peer)
            XCTAssertNil(removerEntry, "the removing side stops trusting at once")
            let notice = try XCTUnwrap(harness.transport.lastSent(.unpairNotice, from: remover.id))
            XCTAssertEqual(notice.recordType, .quiet)
            XCTAssertEqual(notice.expiresAt.timeIntervalSince(notice.sentAt), 30 * 24 * 60 * 60)

            // The peer's messages are refused from now on.
            try await peer.messenger.sendDeliveryCheck(to: remover.id)
            await XCTAssertNotNilAsync(try await peer.entry(for: remover), "the peer keeps its entry until it processes the notice")
            let report = try await remover.poll()
            XCTAssertEqual(report.refusals, [.unknownSender])

            try await peer.poll()
            let peerEntry = try await peer.entry(for: remover)
            XCTAssertNil(peerEntry)
        }
    }

    func testListChangePreparedBeforeARemovalDoesNotBringTheDeviceBack() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        try await phone.poll()
        try await mac.messenger.removeDevice(phone.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.unknownSender])
        let macDevices = try await mac.devices()
        XCTAssertTrue(macDevices.isEmpty)

        // The same rule at the registry: changes prepared against the removed entry are dropped.
        let entry = try await XCTUnwrapAsync(try await phone.entry(for: mac))
        let registry = PairedDeviceRegistry(store: phone.store)
        let prepared: [PairedDeviceChange] = [
            .recordReached(mac.id, pairingID: entry.pairingID, at: harness.clock.now()),
            .rename(mac.id, pairingID: entry.pairingID, displayName: "Renamed"),
            .recordDeliveryCheck(mac.id, pairingID: entry.pairingID, result: .replied(at: harness.clock.now())),
            .remove(mac.id, pairingID: entry.pairingID),
        ]
        try await registry.apply(.remove(mac.id, pairingID: entry.pairingID))
        for change in prepared {
            let outcome = try await registry.apply(change)
            XCTAssertEqual(outcome, .dropped)
        }
        let phoneDevices = try await registry.list().devices
        XCTAssertTrue(phoneDevices.isEmpty)
    }

    func testMessagesFromAnEarlierPairingAreRefusedAfterPairingAgain() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)

        // The first pairing's reply and unpair notice are held back by a writer to the account.
        harness.transport.dropping(.deliveryCheckReply)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        try await phone.poll()
        let oldReply = try XCTUnwrap(harness.transport.lastSent(.deliveryCheckReply, from: phone.id))
        harness.transport.dropping(.unpairNotice)
        try await phone.messenger.removeDevice(mac.id)
        let oldNotice = try XCTUnwrap(harness.transport.lastSent(.unpairNotice, from: phone.id))
        harness.transport.interceptor = nil
        try await mac.messenger.removeDevice(phone.id)
        try await phone.poll()

        harness.clock.advance(by: 60)
        try await harness.pair(mac, phone)
        let current = try await XCTUnwrapAsync(try await mac.entry(for: phone)).pairingID
        harness.transport.insert(oldNotice, intoInboxOf: mac.id)
        harness.transport.insert(oldReply, intoInboxOf: mac.id)
        let report = try await mac.poll()
        XCTAssertEqual(report.refusals, [.bindingMismatch, .bindingMismatch])
        let entry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        XCTAssertEqual(entry.pairingID, current)
        XCTAssertFalse(entry.isReached)
    }

    func testReplyToADifferentCheckIsRefused() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        try await phone.poll()
        let firstReply = try XCTUnwrap(harness.transport.lastSent(.deliveryCheckReply, from: phone.id))
        await XCTAssertEqualAsync(try await mac.poll().processed, 1)

        // After a restart nothing is remembered as processed; the old reply
        // still answers only the check it was for.
        mac.restart()
        harness.transport.dropping(.deliveryCheck)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        harness.transport.interceptor = nil
        harness.transport.insert(firstReply, intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.bindingMismatch])
    }

    func testRenameCleansTheNameAndUnknownDevicesAreReported() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        try await mac.messenger.renameDevice(phone.id, to: "  Work\u{202E} Phone\n ")
        await XCTAssertEqualAsync(try await mac.entry(for: phone)?.displayName, "Work Phone")
        let stranger = harness.makeDevice(.iOS)
        do {
            try await mac.messenger.renameDevice(stranger.id, to: "Nobody")
            XCTFail("renaming an unknown device throws")
        } catch DeviceMessengerError.unknownDevice {}
        do {
            try await mac.messenger.removeDevice(stranger.id)
            XCTFail("removing an unknown device throws")
        } catch DeviceMessengerError.unknownDevice {}
    }
}
