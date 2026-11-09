@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

final class PairingRuleTests: XCTestCase {
    func testResponderWithoutAChallengeWithdrawsAfterSixtySeconds() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        harness.transport.dropping(.pairingChallenge)
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        harness.clock.advance(by: 59)
        await phone.messenger.advanceTimers()
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge)
        harness.clock.advance(by: 1)
        await phone.messenger.advanceTimers()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .noChallenge)
        let withdrawal = try XCTUnwrap(harness.transport.lastSent(.pairingWithdrawal, from: phone.id))
        XCTAssertEqual(withdrawal.recordType, .quiet)
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .cancelledByPeer)
        let macDevices = try await mac.devices()
        XCTAssertTrue(macDevices.isEmpty)
    }

    func testConfirmationWithTheWrongRoleOrSignerIsRefused() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        harness.transport.dropping(.pairingConfirmation, from: phone.id)
        try await phone.messenger.confirmPairing(approvalReason: "Pair")
        let genuine = try XCTUnwrap(harness.transport.lastSent(.pairingConfirmation, from: phone.id))
        let transcriptHash = try Self.open(genuine, with: mac).payload.subdata(in: 17..<49)

        let stranger = SoftwareDeviceIdentity()
        for (role, signer) in [(PairingRole.initiator, phone.id), (.responder, mac.id),
                               (.responder, DeviceID(messagePublicKey: stranger.messagePublicKey))] {
            let signature = try await phone.identity.signWithApprovalKey(
                PairingConfirmationPayload.signedBytes(role: role, signer: signer, transcriptHash: transcriptHash),
                reason: "test")
            let payload = PairingConfirmationPayload.encode(role: role, signer: signer, transcriptHash: transcriptHash,
                                                            signature: signature)
            harness.transport.insert(try Self.seal(.pairingConfirmation, payload, from: phone, to: mac, harness: harness),
                                     intoInboxOf: mac.id)
            let report = try await mac.poll()
            XCTAssertEqual(report.refusals, [.bindingMismatch], "\(role) \(signer)")
        }
        // A confirmation whose approval signature is by the message key is refused too.
        let fields = PairingConfirmationPayload.fields(role: .responder, signer: phone.id, transcriptHash: transcriptHash)
        let wrongKey = try phone.identity.signWithMessageKey(DomainLabel.pairingConfirmation + fields)
        harness.transport.insert(try Self.seal(.pairingConfirmation, fields + wrongKey, from: phone, to: mac, harness: harness),
                                 intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.bindingMismatch])

        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("no valid confirmation from the phone yet") }
        harness.transport.insert(genuine, intoInboxOf: mac.id)
        try await mac.poll()
        guard case .paired = await mac.phase() else { return XCTFail("the genuine confirmation completes the pairing") }
    }

    func testRequestFirstFetchedMoreThanThirtySecondsAfterTheQRExpiryIsNotFrozen() async throws {
        for (delay, frozen) in [(29.0, true), (31.0, false)] {
            let harness = DeviceHarness()
            let mac = harness.makeDevice(.macOS)
            let phone = harness.makeDevice(.iOS)
            let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
            harness.clock.advance(by: PairingSession.qrLifetime - 10)
            try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
            harness.clock.advance(by: 10 + delay)
            let report = try await mac.poll()
            if frozen {
                await XCTAssertNotNilAsync(await mac.code(), "fetched \(delay) s after the QR expiry")
            } else {
                XCTAssertEqual(report.refusals, [.requestTooLate])
                guard case .showingQRCode = await mac.phase() else { return XCTFail("nothing frozen") }
            }
        }
    }

    func testChallengeThatFailsToSendIsResentWithTheSameMessageID() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        harness.transport.failNextSends(with: [.networkUnavailable, .networkUnavailable])
        let first = try await mac.poll()
        XCTAssertEqual(first.processed, 1, "frozen; the challenge waits in the outbox")
        XCTAssertNil(harness.transport.records(in: phone.id).first)
        harness.clock.advance(by: 5)
        try await mac.poll()
        XCTAssertEqual(harness.transport.records(in: phone.id).count, 1, "the challenge is resent")
        let attempts = harness.transport.sentEnvelopes.filter { $0.kind == Int64(MessageKind.pairingChallenge.rawValue) }
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(Set(attempts.map(\.recordName)).count, 1)
        try await phone.poll()
        await XCTAssertNotNilAsync(await phone.code())
    }

    func testNinthPairingIsRefused() async throws {
        let harness = DeviceHarness()
        let full = try PairedDeviceList(devices: (0..<8).map { _ in try Self.syntheticEntry(harness) })
        let mac = harness.makeDevice(.macOS, list: full)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Ninth Phone")
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .deviceLimitReached)
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .cancelledByPeer)
        let macDevices = try await mac.devices()
        let phoneDevices = try await phone.devices()
        XCTAssertEqual(macDevices.count, 8)
        XCTAssertTrue(phoneDevices.isEmpty)

        let fullPhone = harness.makeDevice(.iOS, list: full)
        let other = harness.makeDevice(.macOS)
        let otherQR = try await other.messenger.startPairing(displayName: "Other Mac")
        do {
            try await fullPhone.messenger.joinPairing(scannedText: otherQR.text, displayName: "Full Phone")
            XCTFail("a responder with 8 devices refuses a ninth")
        } catch DeviceMessengerError.deviceLimitReached {}
    }

    func testPairingAgainReplacesTheEntryAndPairingID() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        let first = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        harness.clock.advance(by: 11 * 60)
        try await harness.pair(mac, phone)
        let second = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        let macDevices = try await mac.devices()
        XCTAssertEqual(macDevices.count, 1)
        XCTAssertNotEqual(first.pairingID, second.pairingID)
        await XCTAssertEqualAsync(try await phone.entry(for: mac)?.pairingID, second.pairingID)
    }

    func testCardThatReusesThisDevicesKeyIsRefused() async throws {
        let harness = DeviceHarness()
        let macMessageKey = P256.Signing.PrivateKey()
        let macApprovalKey = P256.Signing.PrivateKey()
        let mac = harness.makeDevice(.macOS, identity: SoftwareDeviceIdentity(
            messageKey: macMessageKey, agreementKey: P256.KeyAgreement.PrivateKey(), approvalKey: macApprovalKey))
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        // The Mac refuses a card that reuses its approval key, which the QR code does not show.
        let copycat = harness.makeDevice(.iOS, identity: SoftwareDeviceIdentity(
            messageKey: P256.Signing.PrivateKey(), agreementKey: P256.KeyAgreement.PrivateKey(), approvalKey: macApprovalKey))
        try await copycat.messenger.joinPairing(scannedText: qr.text, displayName: "Copycat")
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.keyConflict])
        guard case .showingQRCode = await mac.phase() else { return XCTFail("nothing frozen") }
        // A responder refuses a code whose keys are its own.
        let mirror = harness.makeDevice(.iOS, identity: SoftwareDeviceIdentity(
            messageKey: P256.Signing.PrivateKey(), agreementKey: P256.KeyAgreement.PrivateKey(), approvalKey: macMessageKey))
        do {
            try await mirror.messenger.joinPairing(scannedText: qr.text, displayName: "Mirror")
            XCTFail("the code's keys equal the responder's own")
        } catch DeviceMessengerError.keyConflict {}

        do {
            try await mac.messenger.joinPairing(scannedText: qr.text, displayName: "Itself")
            XCTFail("a device cannot answer its own code")
        } catch DeviceMessengerError.keyConflict {}
    }

    func testUnusableIdentityEndsTheSession() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        phone.identity.isUnusable = true
        do {
            try await phone.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("an unusable approval key throws")
        } catch DeviceIdentityError.unusable {}
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .identityUnusable)
        await mac.messenger.cancelPairing()
        do {
            try await phone.poll()
            XCTFail("a key-agreement key that no longer works is reported, not treated as a refusal")
        } catch DeviceIdentityError.unusable {}
    }

    // MARK: Helpers

    static func syntheticEntry(_ harness: DeviceHarness) throws -> PairedDevice {
        let card = try DeviceCard.make(identity: SoftwareDeviceIdentity(), platform: .iOS, createdAt: harness.clock.now())
        return PairedDevice(card: card, pairingID: PairingID(rawValue: RandomBytes.make(16))!, displayName: "Synthetic",
                            pairedAt: harness.clock.now())
    }

    /// Opens an envelope with the recipient's keys, as only the recipient can.
    static func open(_ envelope: DeviceEnvelope, with recipient: SimulatedDevice,
                     preSharedKey: HPKEPreSharedKey? = nil) throws -> InnerMessage {
        let now = Date(timeIntervalSince1970: TimeInterval(UnixTime.exactSeconds(envelope.sentAt)!))
        let routing = try MessageCodec.routing(of: envelope, ownID: recipient.id, now: now)
        return try MessageCodec.open(envelope, routing: routing, ownID: recipient.id, identity: recipient.identity,
                                     preSharedKey: preSharedKey, now: now)
    }

    /// Seals a message signed by `sender`'s real message key.
    static func seal(_ kind: MessageKind, _ payload: Data, from sender: SimulatedDevice, to recipient: SimulatedDevice,
                     harness: DeviceHarness, lifetime: Int64 = 300, sentOffset: Int64 = 0) throws -> DeviceEnvelope {
        let sentAt = UnixTime.seconds(harness.clock.now()) + sentOffset
        return try MessageCodec.seal(kind: kind, payload: payload, identity: sender.identity, recipient: recipient.id,
                                     recipientKey: recipient.identity.agreementPublicKey, preSharedKey: nil,
                                     sentAt: sentAt, expiresAt: sentAt + lifetime).envelope
    }
}
