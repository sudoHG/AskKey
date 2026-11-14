@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// ADR 0013's refusal rules apply to each of kinds 10–14: each case is
/// refused without effect and deleted, and the stateless verifier gives the
/// same verdict (#310 acceptance 3 and 5).
final class ApprovalTransportRuleTests: XCTestCase {
    private var fixture: ApprovalFixture!

    override func setUp() async throws {
        fixture = try await ApprovalFixture.make()
    }

    private var now: Int64 { UnixTime.seconds(fixture.harness.clock.now()) }

    /// A valid payload of `kind` sealed at `sentAt`, its sender and recipient,
    /// and its usual lifetime.
    private func message(_ kind: MessageKind, sentAt: Int64) async throws
        -> (payload: Data, sender: SimulatedDevice, recipient: SimulatedDevice, lifetime: Int64) {
        let pairingID = try await fixture.macEntryForPhone().pairingID
        let digest = Data(SHA256.hash(data: Data("request".utf8)))
        switch kind {
        case .approvalRequest:
            let request = try ApprovalRequest.build(display: ApprovalVectorTests.vectorDisplay, pairingID: pairingID,
                                                    responseID: .random(), bindingDigest: ApprovalFixture.binding,
                                                    deadline: sentAt + 120, launchTime: 1_799_000_000,
                                                    offers: .denyOrAllowOnce, timedDuration: 0)
            return (request.encoded, fixture.mac, fixture.phone, 420)
        case .approvalDecision:
            return (ApprovalDecision.encode(pairingID: pairingID, requestDigest: digest, code: .deny, durationCeiling: 0,
                                            slot: Data(count: 64)), fixture.phone, fixture.mac, 600)
        case .approvalClosed:
            return (ApprovalClosed.encode(pairingID: pairingID, requestDigest: digest, outcome: .expired, appliedCode: nil,
                                          appliedDuration: 0), fixture.mac, fixture.phone, 600)
        case .approvalReceipt:
            return (ApprovalReceipt.encode(pairingID: pairingID, requestDigest: digest), fixture.phone, fixture.mac, 600)
        case .approverConfirmation:
            let proof = ApproverCode.random().proof(mac: fixture.mac.id, phone: fixture.phone.id, pairingID: pairingID)
            let statement = ApproverConfirmation.statement(phone: fixture.phone.id, mac: fixture.mac.id,
                                                           pairingID: pairingID, codeProof: proof)
            let signature = try await fixture.phone.identity.signWithApprovalKey(statement, reason: "test")
            return (ApproverConfirmation.encode(pairingID: pairingID, codeProof: proof, signature: signature),
                    fixture.phone, fixture.mac, 600)
        default:
            fatalError("not an approval kind")
        }
    }

    private static let kinds: [MessageKind] = [.approvalRequest, .approvalDecision, .approvalClosed, .approvalReceipt,
                                               .approverConfirmation]

    private func sealed(_ kind: MessageKind, sentAtOffset: Int64 = 0, lifetime: Int64? = nil,
                        identity: (any DeviceIdentity)? = nil) async throws -> (DeviceEnvelope, SimulatedDevice) {
        let sentAt = now + sentAtOffset
        let message = try await message(kind, sentAt: sentAt)
        let envelope = try MessageCodec.seal(kind: kind, payload: message.payload,
                                             identity: identity ?? message.sender.identity, recipient: message.recipient.id,
                                             recipientKey: message.recipient.identity.agreementPublicKey,
                                             preSharedKey: nil, sentAt: sentAt,
                                             expiresAt: sentAt + (lifetime ?? message.lifetime)).envelope
        return (envelope, message.recipient)
    }

    func testValidMessagesOfEveryKindPassAndAReinsertedCopyIsReplayed() async throws {
        for kind in Self.kinds {
            let (envelope, recipient) = try await sealed(kind)
            let verdict = try DeviceMessageVerifier(identity: recipient.identity,
                                                    list: try recipient.store.loadPairedDeviceList())
                .verify(envelope, now: recipient.clock.now())
            guard case .approval(let verified) = verdict else { return XCTFail("\(kind) verifies, got \(verdict)") }
            XCTAssertEqual(verified.envelope, envelope)
            fixture.harness.transport.insert(envelope, intoInboxOf: recipient.id)
            let first = try await recipient.poll()
            XCTAssertEqual(first.processed + first.refusals.count, 1, "\(kind) reached the handler")
            XCTAssertFalse(first.refusals.contains { $0 != .bindingMismatch }, "\(kind): only the App refuses it")
            try await fixture.assertRefused(envelope, at: recipient, .replayed, checkVerifier: false)
        }
    }

    func testUnknownSenderIsRefused() async throws {
        for kind in Self.kinds {
            let (envelope, recipient) = try await sealed(kind, identity: SoftwareDeviceIdentity())
            try await fixture.assertRefused(envelope, at: recipient, .unknownSender)
        }
    }

    func testBadMessageKeySignatureIsRefused() async throws {
        for kind in Self.kinds {
            let claimed = try await message(kind, sentAt: now).sender.identity
            let (envelope, recipient) = try await sealed(kind, identity: ForgedSigner(claimed: claimed))
            try await fixture.assertRefused(envelope, at: recipient, .badSignature)
        }
    }

    func testRoutingAndTamperingRulesApply() async throws {
        let stranger = SoftwareDeviceIdentity().deviceID.text
        let cases: [(String, DeviceMessageRefusal, (DeviceEnvelope) -> DeviceEnvelope)] = [
            ("wrong recipient", .wrongRecipient, { var e = $0; e.recipient = stranger; return e }),
            ("record type", .recordTypeMismatch, { var e = $0; e.recordType = e.recordType == .alert ? .quiet : .alert; return e }),
            ("sent time", .routingMismatch, { var e = $0; e.sentAt += 1; return e }),
            ("expiry", .routingMismatch, { var e = $0; e.expiresAt -= 1; return e }),
            ("record name", .routingMismatch, { var e = $0; e.recordName = MessageID.random().text; return e }),
            ("sender", .routingMismatch, { var e = $0; e.sender = stranger; return e }),
            ("ciphertext", .decryptionFailed, { var e = $0; e.body[e.body.count - 1] ^= 1; return e }),
            ("unknown kind", .unknownKind, { var e = $0; e.kind = 15; return e }),
            ("non-canonical name", .malformed, { var e = $0; e.recordName = e.recordName.uppercased(); return e }),
            ("fractional time", .malformed, { var e = $0; e.sentAt += 0.5; return e }),
            ("pairing request kind", .noSession, { var e = $0; e.kind = 1; e.recordType = .quiet; return e }),
            ("pairing withdrawal kind", .noSession, { var e = $0; e.kind = 5; e.recordType = .quiet; return e }),
        ]
        for kind in Self.kinds {
            for (name, refusal, change) in cases {
                let (envelope, recipient) = try await sealed(kind)
                let refusal = name == "sender" ? DeviceMessageRefusal.decryptionFailed : refusal
                try await fixture.assertRefused(change(envelope), at: recipient, refusal)
            }
            // Another approval kind with the same record type: the signed kind differs.
            if kind != .approvalRequest {
                let (envelope, recipient) = try await sealed(kind)
                var changed = envelope
                changed.kind = kind == .approvalDecision ? 13 : 11
                try await fixture.assertRefused(changed, at: recipient, .routingMismatch)
            }
        }
    }

    func testTimeRulesApply() async throws {
        for kind in Self.kinds {
            let (expired, recipient) = try await sealed(kind, sentAtOffset: -600, lifetime: 600)
            try await fixture.assertRefused(expired, at: recipient, .expired)
            let (future, _) = try await sealed(kind, sentAtOffset: 301)
            try await fixture.assertRefused(future, at: recipient, .sentInFuture)
            let (long, _) = try await sealed(kind, lifetime: 601)
            try await fixture.assertRefused(long, at: recipient, .lifetimeTooLong)
            for lifetime: Int64 in [0, -5] {
                let (backwards, _) = try await sealed(kind, sentAtOffset: 10, lifetime: lifetime)
                try await fixture.assertRefused(backwards, at: recipient, .malformed)
            }
            let (atLimit, _) = try await sealed(kind, sentAtOffset: 300)
            fixture.harness.transport.insert(atLimit, intoInboxOf: recipient.id)
            let report = try await recipient.poll()
            XCTAssertFalse(report.refusals.contains(.sentInFuture), "\(kind): 5 minutes ahead is still fresh")
        }
    }

    func testAPreSharedKeyKindNeedsTheOpenSessionsKey() async throws {
        // With a pairing session open on the Mac, a decision relabelled as a
        // pairing request is opened with the session's pre-shared key and fails.
        _ = try await fixture.mac.messenger.startPairing(displayName: "Studio Mac")
        let (envelope, recipient) = try await sealed(.approvalDecision)
        var relabelled = envelope
        relabelled.kind = 1
        try await fixture.assertRefused(relabelled, at: recipient, .decryptionFailed, checkVerifier: false)
        let verdict = try DeviceMessageVerifier(identity: recipient.identity, list: try recipient.store.loadPairedDeviceList())
            .verify(relabelled, now: recipient.clock.now())
        XCTAssertEqual(verdict, .refused(.noSession), "the stateless verifier has no session")
    }

    func testAnInnerPayloadOverSixteenKiBIsRefused() async throws {
        let (mac, phone) = (fixture.mac!, fixture.phone!)
        XCTAssertThrowsError(try MessageCodec.seal(kind: .approvalRequest, payload: Data(count: 16_385), identity: mac.identity,
                                                   recipient: phone.id, recipientKey: phone.identity.agreementPublicKey,
                                                   preSharedKey: nil, sentAt: now, expiresAt: now + 300),
                             "sealing a larger payload fails")
        // A writer with the Mac's message key could still encrypt one by hand.
        let messageID = MessageID.random()
        var writer = ByteWriter()
        writer.append(1)
        writer.append(MessageKind.approvalRequest.rawValue)
        writer.append(mac.id.rawValue)
        writer.append(phone.id.rawValue)
        writer.append(messageID.rawValue)
        writer.appendTime(now)
        writer.appendTime(now + 300)
        writer.appendLengthPrefixed(Data(count: 16_385))
        let inner = writer.data + (try mac.identity.signWithMessageKey(DomainLabel.message + writer.data))
        var sender = try HPKE.Sender(recipientKey: phone.identity.agreementPublicKey, ciphersuite: MessageCodec.ciphersuite,
                                     info: MessageCodec.info(sender: mac.id, recipient: phone.id))
        let ciphertext = try sender.seal(inner)
        let envelope = DeviceEnvelope(recordType: .alert, recordName: messageID.text, sender: mac.id.text,
                                      recipient: phone.id.text, kind: 10, sentAt: UnixTime.date(now),
                                      expiresAt: UnixTime.date(now + 300),
                                      body: Data([1]) + sender.encapsulatedKey + ciphertext)
        try await fixture.assertRefused(envelope, at: phone, .malformed)
    }

    func testMalformedPayloadsAreRefused() async throws {
        for kind in Self.kinds {
            let message = try await message(kind, sentAt: now)
            for payload in [message.payload + [0], message.payload.dropLast(), Data()] {
                let envelope = try ApprovalFixture.seal(kind, Data(payload), from: message.sender, to: message.recipient,
                                                        sentAt: now, lifetime: message.lifetime)
                try await fixture.assertRefused(envelope, at: message.recipient, .malformed)
            }
        }
    }
}

/// Claims another device's keys but signs with a key of its own, so its
/// messages carry the right sender and a wrong signature.
private struct ForgedSigner: DeviceIdentity, @unchecked Sendable {
    let claimed: any DeviceIdentity
    let key = P256.Signing.PrivateKey()

    var messagePublicKey: P256.Signing.PublicKey { claimed.messagePublicKey }
    var agreementPublicKey: P256.KeyAgreement.PublicKey { claimed.agreementPublicKey }
    var approvalPublicKey: P256.Signing.PublicKey { claimed.approvalPublicKey }

    func signWithMessageKey(_ data: Data) throws -> Data {
        try key.signature(for: data).rawRepresentation
    }

    func signWithApprovalKey(_ data: Data, reason: String) async throws -> Data {
        try key.signature(for: data).rawRepresentation
    }

    func openHPKE(_ ciphertext: Data, encapsulatedKey: Data, info: Data, preSharedKey: HPKEPreSharedKey?) throws -> Data {
        throw DeviceIdentityError.unusable
    }
}
