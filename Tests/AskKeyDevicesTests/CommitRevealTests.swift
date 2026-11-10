@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// The responder's commitment (ADR 0013 → Pairing): its request commits to
/// a random secret, which it reveals in kind 9 only after a verified
/// challenge; the transcript, and so the code, covers both.
final class CommitRevealTests: XCTestCase {
    func testRequestCommitsToTheSecretTheRevealDisclosesAndTheTranscriptCoversBoth() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()

        let requestEnvelope = try XCTUnwrap(harness.transport.lastSent(.pairingRequest, from: phone.id))
        let request = try PairingRuleTests.open(requestEnvelope, with: mac, preSharedKey: qr.preSharedKey)
        let requestPayload = try PairingRequestPayload(decoding: request.payload)
        let challenge = try PairingRuleTests.open(try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.id)),
                                                  with: phone)
        let challengePayload = try PairingChallengePayload(decoding: challenge.payload)
        XCTAssertEqual(challengePayload.requestDigest, request.digest, "the frozen request's digest covers the commitment")

        let revealEnvelope = try XCTUnwrap(harness.transport.lastSent(.pairingReveal, from: phone.id))
        XCTAssertEqual(revealEnvelope.recordType, .quiet)
        XCTAssertEqual(revealEnvelope.kind, 9)
        let reveal = try PairingRevealPayload(decoding: try PairingRuleTests.open(revealEnvelope, with: mac).payload)
        XCTAssertEqual(reveal.sessionID, qr.sessionID)
        XCTAssertEqual(reveal.challengeDigest, challenge.digest)
        XCTAssertEqual(PairingDerivation.commitment(sessionID: qr.sessionID, secret: reveal.secret), requestPayload.commitment)

        let transcript = PairingDerivation.transcriptHash(qrPayload: qr.bytes, responderCard: requestPayload.card.bytes,
                                                          commitment: requestPayload.commitment,
                                                          initiatorCard: challengePayload.card.bytes,
                                                          nonce: challengePayload.nonce, revealedSecret: reveal.secret)
        let expected = PairingDerivation.comparisonCode(secret: qr.secret, transcriptHash: transcript)
        await XCTAssertEqualAsync(await phone.code(), expected)
        await XCTAssertEqualAsync(await mac.derivedCode(), expected)
    }

    func testRevealThatDoesNotMatchTheCommitmentEndsTheSession() async throws {
        let (harness, mac, phone, qr) = try await sessionWithTheRevealDropped()
        let forged = PairingRevealPayload(sessionID: qr.sessionID, challengeDigest: try challengeDigest(harness, mac, phone),
                                          secret: RandomBytes.make(32))
        harness.transport.insert(try PairingRuleTests.seal(.pairingReveal, forged.encoded, from: phone, to: mac,
                                                           harness: harness), intoInboxOf: mac.id)
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .commitmentMismatch)
        await XCTAssertNilAsync(await mac.derivedCode())
        XCTAssertNotNil(harness.transport.lastSent(.pairingCancellation, from: mac.id), "a signed cancellation")
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .cancelledByPeer)
        await XCTAssertNilAsync(try await mac.entry(for: phone))
        await XCTAssertNilAsync(try await phone.entry(for: mac))
    }

    func testRevealsFromAnotherDeviceOrWithTheWrongBindingAreRefused() async throws {
        let (harness, mac, phone, qr) = try await sessionWithTheRevealDropped()
        let digest = try challengeDigest(harness, mac, phone)
        let onlooker = harness.makeDevice(.iOS)
        let cases: [(SimulatedDevice, PairingRevealPayload, DeviceMessageRefusal)] = [
            (onlooker, PairingRevealPayload(sessionID: qr.sessionID, challengeDigest: digest, secret: RandomBytes.make(32)),
             .unknownSender),
            (phone, PairingRevealPayload(sessionID: qr.sessionID, challengeDigest: RandomBytes.make(32),
                                         secret: RandomBytes.make(32)), .bindingMismatch),
            (phone, PairingRevealPayload(sessionID: .random(), challengeDigest: digest, secret: RandomBytes.make(32)),
             .bindingMismatch),
        ]
        for (sender, payload, refusal) in cases {
            harness.transport.insert(try PairingRuleTests.seal(.pairingReveal, payload.encoded, from: sender, to: mac,
                                                               harness: harness), intoInboxOf: mac.id)
            await XCTAssertEqualAsync(try await mac.poll().refusals, [refusal])
            guard case .waitingForResponder = await mac.phase() else { return XCTFail("the session is untouched") }
        }
        // The frozen phone's own reveal still completes the code.
        let real = try XCTUnwrap(harness.transport.lastSent(.pairingReveal, from: phone.id))
        harness.transport.insert(real, intoInboxOf: mac.id)
        try await mac.poll()
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else { return XCTFail("the Mac asks for the code") }
        await XCTAssertEqualAsync(await mac.derivedCode(), await phone.code())
    }

    func testCodeEntryBeforeTheRevealIsRefusedWithoutCounting() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        harness.transport.delaying(.pairingReveal)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.poll()
        guard case .waitingForResponder = await mac.phase() else { return XCTFail("no code before the reveal") }
        for text in [code.digits, Self.wrong(code), Self.wrong(code), Self.wrong(code)] {
            do {
                try await mac.messenger.enterPairingCode(text)
                XCTFail("there is no code to enter yet")
            } catch DeviceMessengerError.notAwaitingConfirmation {}
        }
        do {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("nothing to confirm yet")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        XCTAssertNil(harness.transport.lastSent(.pairingCancellation, from: mac.id), "nothing was counted")

        harness.transport.releaseDelayed()
        try await mac.poll()
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else { return XCTFail("all attempts remain") }
        try await mac.messenger.enterPairingCode(code.digits)
        guard case .codeAccepted = await mac.phase() else { return XCTFail("the code is accepted after the reveal") }
    }

    func testRepeatedRevealIsIgnored() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        harness.transport.interceptor = { $0.kind == Int64(MessageKind.pairingReveal.rawValue) ? .duplicate : .deliver }
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        let code = try await XCTUnwrapAsync(await mac.derivedCode())
        do {
            try await mac.messenger.enterPairingCode(Self.wrong(code))
            XCTFail("a wrong code is refused")
        } catch DeviceMessengerError.wrongCode(attemptsRemaining: 2) {}

        harness.transport.releaseDelayed()
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.replayed], "the same reveal again")
        // Another verified reveal, even with a different secret, changes nothing either.
        let other = PairingRevealPayload(sessionID: qr.sessionID, challengeDigest: try challengeDigest(harness, mac, phone),
                                         secret: RandomBytes.make(32))
        harness.transport.interceptor = nil
        harness.transport.insert(try PairingRuleTests.seal(.pairingReveal, other.encoded, from: phone, to: mac,
                                                           harness: harness), intoInboxOf: mac.id)
        let report = try await mac.poll()
        XCTAssertEqual(report.processed, 1)
        XCTAssertTrue(report.refusals.isEmpty)
        guard case .enteringCode(_, attemptsRemaining: 2) = await mac.phase() else { return XCTFail("unchanged") }
        await XCTAssertEqualAsync(await mac.derivedCode(), code)
    }

    func testResentRequestKeepsItsCommitmentAndMessageID() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        harness.transport.failNextSends(with: [.networkUnavailable])
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        harness.clock.advance(by: 5)
        await phone.messenger.advanceTimers()
        let attempts = harness.transport.sentEnvelopes.filter {
            $0.kind == Int64(MessageKind.pairingRequest.rawValue) && $0.sender == phone.id.text
        }
        XCTAssertEqual(attempts.count, 2, "sent again after the failure")
        let opened = try attempts.map { try PairingRuleTests.open($0, with: mac, preSharedKey: qr.preSharedKey) }
        XCTAssertEqual(Set(opened.map(\.messageID)).count, 1)
        let commitments = try opened.map { try PairingRequestPayload(decoding: $0.payload).commitment }
        XCTAssertEqual(Set(commitments).count, 1)
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        guard case .enteringCode = await mac.phase() else { return XCTFail("the reveal matches the resent commitment") }
    }

    func testResponderShowsNoCodeUntilItsRevealIsSent() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        harness.transport.failNextSends(with: [.networkUnavailable, .networkUnavailable, .networkUnavailable])
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge, "the challenge is verified, the reveal not sent")
        await XCTAssertNilAsync(await phone.code())
        do {
            try await phone.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("nothing to confirm before the reveal is sent")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        XCTAssertTrue(phone.identity.approvalReasons.isEmpty)

        harness.transport.failNextSends(with: [])
        harness.clock.advance(by: 5)
        await phone.messenger.advanceTimers()
        guard case .showingCode = await phone.phase() else { return XCTFail("the code appears once the reveal is sent") }
        let reveals = harness.transport.sentEnvelopes.filter {
            $0.kind == Int64(MessageKind.pairingReveal.rawValue) && $0.sender == phone.id.text
        }
        XCTAssertGreaterThanOrEqual(reveals.count, 2)
        XCTAssertEqual(Set(reveals.map(\.recordName)).count, 1, "resent with the same message ID")
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.derivedCode(), await phone.code())
    }

    func testAVerifiedChallengeWithOtherBytesEndsTheResponderSession() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        guard case .showingCode = await phone.phase() else { return XCTFail("the phone froze the first challenge") }
        // The Mac's key signs a second challenge with another nonce for the same request.
        let request = try PairingRuleTests.open(try XCTUnwrap(harness.transport.lastSent(.pairingRequest, from: phone.id)),
                                                with: mac, preSharedKey: qr.preSharedKey)
        let macCard = try DeviceCard.make(identity: mac.identity, platform: .macOS, createdAt: harness.clock.now())
        let second = PairingChallengePayload(sessionID: qr.sessionID, requestDigest: request.digest, card: macCard,
                                             nonce: RandomBytes.make(32), displayName: "Studio Mac")
        harness.transport.insert(try PairingRuleTests.seal(.pairingChallenge, second.encoded, from: mac, to: phone,
                                                           harness: harness), intoInboxOf: phone.id)
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .conflictingChallenge)
        await XCTAssertNilAsync(await phone.code())
        XCTAssertNotNil(harness.transport.lastSent(.pairingCancellation, from: phone.id), "a signed cancellation")
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .cancelledByPeer)
    }

    func testTheSameChallengeAgainChangesNothing() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let macIdentity = SoftwareDeviceIdentity()
        let phoneIdentity = SoftwareDeviceIdentity()
        var mac = PairingSession.initiate(identity: macIdentity, card: try DeviceCard.make(identity: macIdentity,
                                          platform: .macOS, createdAt: now), displayName: "Studio Mac", now: now)
        var phone = try PairingSession.respond(to: mac.qr, identity: phoneIdentity,
                                               card: try DeviceCard.make(identity: phoneIdentity, platform: .iOS, createdAt: now),
                                               displayName: "Pocket Phone", now: now, list: PairedDeviceList())
        let request = try Self.open(try XCTUnwrap(phone.outbox.first), by: macIdentity, preSharedKey: mac.qr.preSharedKey,
                                    now: now)
        guard case .accepted(let challengeEffects) = try mac.handleRequest(request, firstFetchedAt: now, now: now,
                                                                           list: PairedDeviceList()),
              case .send(let challengeEnvelope)? = challengeEffects.first else { return XCTFail("a challenge") }
        let challenge = try Self.open(challengeEnvelope, by: phoneIdentity, preSharedKey: nil, now: now)
        guard case .accepted(let first) = try phone.handlePeerMessage(challenge, now: now, list: PairedDeviceList()),
              case .send? = first.first else { return XCTFail("a reveal") }
        let derived = phone.code
        guard case .accepted(let again) = try phone.handlePeerMessage(challenge, now: now, list: PairedDeviceList()) else {
            return XCTFail("the same bytes are no conflict")
        }
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(phone.code, derived)
        XCTAssertNil(phone.phase.endReason)

        // Through the inbox, the resent challenge has the same message ID and is a replay.
        let harness = DeviceHarness()
        let macDevice = harness.makeDevice(.macOS)
        let phoneDevice = harness.makeDevice(.iOS)
        let qr = try await macDevice.messenger.startPairing(displayName: "Studio Mac")
        try await phoneDevice.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await macDevice.poll()
        try await phoneDevice.poll()
        let shown = try await XCTUnwrapAsync(await phoneDevice.code())
        let reveals = harness.transport.sentEnvelopes.filter { $0.kind == Int64(MessageKind.pairingReveal.rawValue) }.count
        harness.transport.insert(try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: macDevice.id)),
                                 intoInboxOf: phoneDevice.id)
        await XCTAssertEqualAsync(try await phoneDevice.poll().refusals, [.replayed])
        await XCTAssertEqualAsync(await phoneDevice.code(), shown)
        XCTAssertEqual(harness.transport.sentEnvelopes.filter { $0.kind == Int64(MessageKind.pairingReveal.rawValue) }.count,
                       reveals, "no second reveal")
    }

    func testRevealFromAReplacedSessionIsRefusedByTheNewOne() async throws {
        let (harness, mac, phone, _) = try await sessionWithTheRevealDropped()
        let late = try XCTUnwrap(harness.transport.lastSent(.pairingReveal, from: phone.id))
        let second = try await mac.messenger.startPairing(displayName: "Studio Mac")
        let tablet = harness.makeDevice(.iOS)
        try await tablet.messenger.joinPairing(scannedText: second.text, displayName: "Tablet")
        try await mac.poll()
        guard case .waitingForResponder(let peer) = await mac.phase(), peer.deviceID == tablet.id else {
            return XCTFail("the new session froze the tablet")
        }
        harness.transport.insert(late, intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.unknownSender])
        guard case .waitingForResponder = await mac.phase() else { return XCTFail("the new session is untouched") }
        try await tablet.poll()
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.derivedCode(), await tablet.code())
    }

    func testResponderCancellingBeforeItsRevealIsSentSendsACancellation() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        harness.transport.failNextSends(with: [.networkUnavailable, .networkUnavailable, .networkUnavailable])
        try await phone.poll()
        harness.transport.failNextSends(with: [])
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge, "the reveal is not sent")
        await phone.messenger.cancelPairing()
        XCTAssertNotNil(harness.transport.lastSent(.pairingCancellation, from: phone.id), "the phone knows the Mac")
        XCTAssertNil(harness.transport.lastSent(.pairingWithdrawal, from: phone.id))
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .cancelledByPeer)
    }

    func testRevealsAreProcessedBeforeConfirmationsWithinAFetch() {
        let kinds: [Int64] = [7, 3, 9, 4, 1, 2, 5, 6, 8]
        let envelopes = kinds.map {
            DeviceEnvelope(recordType: .quiet, recordName: "\($0)", sender: "", recipient: "", kind: $0,
                           sentAt: Date(), expiresAt: Date(), body: Data())
        }
        let sorted = envelopes.sorted { DeviceMessenger.rank($0) < DeviceMessenger.rank($1) }
        XCTAssertEqual(sorted.prefix(6).map(\.kind), [1, 2, 9, 3, 4, 5])
    }

    // MARK: Helpers

    /// A Mac that sent its challenge and a phone that verified it, whose
    /// reveal the transport dropped; it stays in `sentEnvelopes`.
    private func sessionWithTheRevealDropped() async throws
        -> (DeviceHarness, SimulatedDevice, SimulatedDevice, PairingQRPayload) {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        harness.transport.dropping(.pairingReveal, from: phone.id)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        harness.transport.interceptor = nil
        try await mac.poll()
        guard case .waitingForResponder = await mac.phase() else {
            XCTFail("the Mac waits for the reveal")
            throw DeviceMessengerError.notAwaitingConfirmation
        }
        return (harness, mac, phone, qr)
    }

    /// The digest of the challenge the Mac sent, as the phone sees it.
    private func challengeDigest(_ harness: DeviceHarness, _ mac: SimulatedDevice, _ phone: SimulatedDevice) throws -> Data {
        try PairingRuleTests.open(try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.id)), with: phone)
            .digest
    }

    private static func open(_ envelope: DeviceEnvelope, by identity: SoftwareDeviceIdentity,
                             preSharedKey: HPKEPreSharedKey?, now: Date) throws -> InnerMessage {
        let ownID = DeviceID(messagePublicKey: identity.messagePublicKey)
        let routing = try MessageCodec.routing(of: envelope, ownID: ownID, now: now)
        return try MessageCodec.open(envelope, routing: routing, ownID: ownID, identity: identity,
                                     preSharedKey: preSharedKey, now: now)
    }

    private static func wrong(_ code: PairingCode) -> String {
        PairingCode(value: (code.value + 1) % 1_000_000).digits
    }
}
