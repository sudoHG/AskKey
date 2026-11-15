@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// Pairing makes the approver (ADR 0014 → Approvers, #336): the entry a
/// pairing adds carries the approval flag on both sides when a macOS
/// initiator pairs with an iOS responder, and no other pairing sets it.
final class PairingApproverTests: XCTestCase {
    func testPairingAMacWithAnIPhoneFlagsTheEntryOnBothSides() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let macEntry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        let phoneEntry = try await XCTUnwrapAsync(try await phone.entry(for: mac))
        XCTAssertTrue(macEntry.isApprover, "the Mac's entry for the iPhone: it may decide the Mac's requests")
        XCTAssertTrue(phoneEntry.isApprover, "the iPhone's entry for the Mac: it accepts the Mac's requests")
        XCTAssertEqual(macEntry.pairingID, phoneEntry.pairingID)
    }

    func testPairingTwoMacsTwoIPhonesOrAnIPhoneInitiatorAddsNoFlag() async throws {
        for (initiator, responder) in [(DevicePlatform.macOS, DevicePlatform.macOS), (.iOS, .iOS), (.iOS, .macOS)] {
            let harness = DeviceHarness()
            let first = harness.makeDevice(initiator)
            let second = harness.makeDevice(responder)
            try await harness.pair(first, second)
            let firstEntry = try await XCTUnwrapAsync(try await first.entry(for: second))
            let secondEntry = try await XCTUnwrapAsync(try await second.entry(for: first))
            XCTAssertFalse(firstEntry.isApprover, "\(initiator) initiator, \(responder) responder")
            XCTAssertFalse(secondEntry.isApprover, "\(initiator) initiator, \(responder) responder")
        }
    }

    func testPairingAgainFlagsTheNewEntry() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let old = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        harness.clock.advance(by: 11 * 60) // The first session has expired.
        try await harness.pair(mac, phone)
        let macEntry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        let phoneEntry = try await XCTUnwrapAsync(try await phone.entry(for: mac))
        XCTAssertNotEqual(macEntry.pairingID, old.pairingID, "pairing again gives a new entry")
        XCTAssertEqual(macEntry.pairingID, phoneEntry.pairingID)
        XCTAssertTrue(macEntry.isApprover)
        XCTAssertTrue(phoneEntry.isApprover)
    }

    /// The Mac adds the iPhone and seals a request before the iPhone holds
    /// the Mac's confirmation: the iPhone keeps it for the session and
    /// processes it once the Mac is listed with its flag.
    func testARequestFromTheSessionPeerIsHeldAndProcessedOnceTheMacIsAdded() async throws {
        let harness = DeviceHarness()
        let inbox = ApprovalInbox()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS, approvalHandler: inbox.handler)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.delaying(.pairingConfirmation, from: mac.id)
        try await phone.confirm()
        try await mac.confirm()
        try await mac.poll()
        let entry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        XCTAssertTrue(entry.isApprover, "the Mac added the iPhone with its flag")
        let sealed = try mac.messenger.sealer.sealApprovalRequest(
            ApprovalVectorTests.vectorDisplay, bindingDigest: ApprovalFixture.binding,
            deadline: harness.clock.now().addingTimeInterval(60), launchTime: harness.clock.now(), offers: .denyOnly,
            timedDuration: 0, to: entry)
        try await harness.transport.send(sealed.sealed.envelope)

        let early = try await phone.poll()
        XCTAssertEqual(early.outcomes[sealed.sealed.envelope.recordName], .keptForSession)
        XCTAssertTrue(inbox.messages.isEmpty, "the handler has not seen it")
        await XCTAssertNilAsync(try await phone.entry(for: mac))

        harness.transport.releaseDelayed()
        let later = try await phone.poll()
        XCTAssertEqual(later.outcomes[sealed.sealed.envelope.recordName], .processed)
        XCTAssertEqual(inbox.messages.map(\.digest), [sealed.requestDigest])
        XCTAssertEqual(inbox.messages.first?.sender.isApprover, true, "the Mac is listed with the iPhone's flag")
    }
}
