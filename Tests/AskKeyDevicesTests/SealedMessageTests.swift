@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

final class SealedMessageTests: XCTestCase {
    private var harness: DeviceHarness!
    private var mac: SimulatedDevice!
    private var phone: SimulatedDevice!

    override func setUp() async throws {
        harness = DeviceHarness()
        mac = harness.makeDevice(.macOS)
        phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
    }

    func testEnvelopeAndBodyFollowTheLayouts() async throws {
        let checkID = try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let envelope = try XCTUnwrap(harness.transport.lastSent(.deliveryCheck, from: mac.id))
        XCTAssertEqual(envelope.recordType, .alert)
        XCTAssertEqual(envelope.recordName, checkID.text)
        XCTAssertEqual(envelope.sender, mac.id.text)
        XCTAssertEqual(envelope.recipient, phone.id.text)
        XCTAssertEqual(envelope.kind, 7)
        XCTAssertEqual(envelope.expiresAt.timeIntervalSince(envelope.sentAt), 600)
        XCTAssertEqual(envelope.body.first, 1)
        XCTAssertEqual(envelope.body[1], 0x04, "the encapsulated key is an uncompressed point")
        let inner = try PairingRuleTests.open(envelope, with: phone)
        XCTAssertEqual(inner.bytes.count, 70 + 16 + 64, "header, the pairing ID, the signature")
        XCTAssertEqual(inner.bytes.first, 1)
        XCTAssertEqual(inner.bytes[1], 7)
        XCTAssertEqual(inner.bytes.subdata(in: 2..<18), mac.id.rawValue)
        XCTAssertEqual(inner.bytes.subdata(in: 18..<34), phone.id.rawValue)
        XCTAssertEqual(inner.bytes.subdata(in: 34..<50), checkID.rawValue)
        XCTAssertEqual(inner.bytes.subdata(in: 66..<70), Data([0, 0, 0, 16]))
        XCTAssertTrue(inner.hasValidSignature(from: mac.identity.messagePublicKey))
        XCTAssertEqual(MessageCodec.info(sender: mac.id, recipient: phone.id),
                       Data("AskKey HPKE v1".utf8) + [0, 1] + mac.id.rawValue + phone.id.rawValue)

        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let second = try XCTUnwrap(harness.transport.lastSent(.deliveryCheck, from: mac.id))
        XCTAssertNotEqual(second.body.subdata(in: 1..<66), envelope.body.subdata(in: 1..<66),
                          "every message uses a new HPKE context")
        for kind in MessageKind.allCases {
            XCTAssertEqual(kind.recordType, kind == .deliveryCheck || kind == .approvalRequest ? .alert : .quiet)
            XCTAssertEqual(kind.usesPreSharedKey, kind == .pairingRequest || kind == .pairingWithdrawal)
        }
    }

    func testTamperedOrRedirectedMessagesAreRefusedAndChangeNothing() async throws {
        let cases: [(String, DeviceMessageRefusal, @Sendable (DeviceEnvelope) -> DeviceEnvelope)] = [
            ("ciphertext", .decryptionFailed, { var e = $0; e.body[e.body.count - 1] ^= 1; return e }),
            ("encapsulated key", .malformed, { var e = $0; e.body[1] = 0x05; return e }),
            ("body version", .malformed, { var e = $0; e.body[0] = 2; return e }),
            ("sent time", .routingMismatch, { var e = $0; e.sentAt += 1; return e }),
            ("expiry", .routingMismatch, { var e = $0; e.expiresAt -= 1; return e }),
            ("record name", .routingMismatch, { var e = $0; e.recordName = MessageID.random().text; return e }),
            ("kind", .routingMismatch, { var e = $0; e.kind = 8; e.recordType = .quiet; return e }),
            ("record type", .recordTypeMismatch, { var e = $0; e.recordType = .quiet; return e }),
            ("unknown kind", .unknownKind, { var e = $0; e.kind = 15; return e }),
            ("sender", .decryptionFailed, { var e = $0; e.sender = DeviceID(rawValue: Data(count: 16))!.text; return e }),
            ("non-canonical sender", .malformed, { var e = $0; e.sender = e.sender.uppercased(); return e }),
            ("fractional time", .malformed, { var e = $0; e.sentAt += 0.5; return e }),
        ]
        for (name, refusal, change) in cases {
            harness.transport.interceptor = { _ in .tamper(change) }
            try await mac.messenger.sendDeliveryCheck(to: phone.id)
            let report = try await phone.poll()
            XCTAssertEqual(report.refusals, [refusal], name)
            XCTAssertTrue(harness.transport.records(in: phone.id).isEmpty, "\(name): refused messages are deleted")
            XCTAssertNil(harness.transport.records(in: mac.id).first, "\(name): no reply")
        }
        await XCTAssertFalseAsync(try await XCTUnwrapAsync(try await phone.entry(for: mac)).isReached)
    }

    func testMessageForOneDeviceIsRefusedByAnother() async throws {
        let tablet = harness.makeDevice(.iOS)
        try await harness.pair(mac, tablet)
        harness.clock.advance(by: 11 * 60)
        harness.transport.dropping(.deliveryCheck)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        var envelope = try XCTUnwrap(harness.transport.lastSent(.deliveryCheck, from: mac.id))
        harness.transport.insert(envelope, intoInboxOf: tablet.id)
        await XCTAssertEqualAsync(try await tablet.poll().refusals, [.wrongRecipient])
        envelope.recipient = tablet.id.text
        harness.transport.insert(envelope, intoInboxOf: tablet.id)
        await XCTAssertEqualAsync(try await tablet.poll().refusals, [.decryptionFailed])
        await XCTAssertFalseAsync(try await XCTUnwrapAsync(try await tablet.entry(for: mac)).isReached)
    }

    func testExpiredReplayedAndUnknownSenderMessagesAreRefused() async throws {
        harness.transport.delaying(.deliveryCheck)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        harness.clock.advance(by: 10 * 60)
        harness.transport.releaseDelayed()
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.expired])

        harness.transport.interceptor = { _ in .duplicate }
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        await XCTAssertEqualAsync(try await phone.poll().processed, 1)
        harness.transport.releaseDelayed()
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.replayed])
        harness.transport.interceptor = nil

        let stranger = harness.makeDevice(.iOS)
        harness.transport.insert(try PairingRuleTests.seal(.deliveryCheck, PairingIDPayload(pairingID: PairingID(rawValue: Data(count: 16))!).encoded,
                                                           from: stranger, to: phone, harness: harness),
                                 intoInboxOf: phone.id)
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.unknownSender])
    }

    func testTimeRulesAndSignaturesAreChecked() async throws {
        let pairingID = try await XCTUnwrapAsync(try await phone.entry(for: mac)).pairingID
        let payload = PairingIDPayload(pairingID: pairingID).encoded
        let future = try PairingRuleTests.seal(.deliveryCheck, payload, from: mac, to: phone, harness: harness, sentOffset: 301)
        let tooLong = try PairingRuleTests.seal(.deliveryCheck, payload, from: mac, to: phone, harness: harness, lifetime: 601)
        let backwards = try PairingRuleTests.seal(.deliveryCheck, payload, from: mac, to: phone, harness: harness,
                                                  lifetime: -1, sentOffset: 100)
        let wrongPairing = try PairingRuleTests.seal(.deliveryCheck, PairingIDPayload(pairingID: PairingID(rawValue: Data(count: 16))!).encoded,
                                                     from: mac, to: phone, harness: harness)
        let trailing = try PairingRuleTests.seal(.deliveryCheck, payload + [0], from: mac, to: phone, harness: harness)
        for (envelope, refusal) in [(future, DeviceMessageRefusal.sentInFuture), (tooLong, .lifetimeTooLong),
                                    (backwards, .malformed), (wrongPairing, .bindingMismatch), (trailing, .malformed)] {
            harness.transport.insert(envelope, intoInboxOf: phone.id)
            await XCTAssertEqualAsync(try await phone.poll().refusals, [refusal])
        }

        // Signed by a key other than the sender's message key.
        let stranger = SoftwareDeviceIdentity()
        let sentAt = UnixTime.seconds(harness.clock.now())
        var writer = ByteWriter()
        writer.append(1)
        writer.append(MessageKind.deliveryCheck.rawValue)
        writer.append(mac.id.rawValue)
        writer.append(phone.id.rawValue)
        let messageID = MessageID.random()
        writer.append(messageID.rawValue)
        writer.appendTime(sentAt)
        writer.appendTime(sentAt + 300)
        writer.appendLengthPrefixed(payload)
        writer.append(try stranger.signWithMessageKey(DomainLabel.message + writer.data))
        var context = try HPKE.Sender(recipientKey: phone.identity.agreementPublicKey, ciphersuite: .P256_SHA256_AES_GCM_256,
                                      info: MessageCodec.info(sender: mac.id, recipient: phone.id))
        let body = Data([1]) + context.encapsulatedKey + (try context.seal(writer.data))
        let forged = DeviceEnvelope(recordType: .alert, recordName: messageID.text, sender: mac.id.text,
                                    recipient: phone.id.text, kind: 7, sentAt: UnixTime.date(sentAt),
                                    expiresAt: UnixTime.date(sentAt + 300), body: body)
        harness.transport.insert(forged, intoInboxOf: phone.id)
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.badSignature])
        await XCTAssertFalseAsync(try await XCTUnwrapAsync(try await phone.entry(for: mac)).isReached)
    }

    func testPairingRequestWithoutAnOpenSessionIsRefused() async throws {
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        await mac.messenger.cancelPairing()
        let other = harness.makeDevice(.iOS)
        try await other.messenger.joinPairing(scannedText: qr.text, displayName: "Other")
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.noSession])
        let report = try await mac.poll()
        XCTAssertEqual(report, InboxReport())
    }
}
