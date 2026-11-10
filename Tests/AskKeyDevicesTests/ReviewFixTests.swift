@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Cases found by the cross review of #293.
final class ReviewFixTests: XCTestCase {
    func testRemovalDuringARepairLeavesTheDeviceRemoved() async throws {
        let harness = DeviceHarness()
        let gated = GatedListStore()
        let mac = SimulatedDevice(identity: SoftwareDeviceIdentity(), store: InMemoryPairedDeviceListStore(), platform: .macOS,
                                  harness: harness, registryStore: gated)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        // Pairing again: the Mac holds the phone's confirmation and is about to confirm.
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await phone.confirm()
        try await mac.poll()
        // The person removes the phone; the removal's write blocks, and the
        // person confirms the new pairing meanwhile.
        gated.closeGate()
        let removing = Task { try await mac.messenger.removeDevice(phone.id) }
        while !gated.isWaiting { await Task.yield() }
        let confirming = Task { try await mac.confirm() }
        // Wait until the confirmation waits to add the phone, or the session already ended.
        for _ in 0..<10_000 {
            let phase = await mac.phase()
            if case .waitingForPeer = phase { break }
            if case .ended = phase { break }
            await Task.yield()
        }
        gated.openGate()
        _ = try await removing.value
        _ = try? await confirming.value
        let devices = try await mac.devices()
        XCTAssertTrue(devices.isEmpty, "no session adds the removed device back")
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .peerRemoved)
    }

    func testConfirmingAfterTheSessionExpiredAddsNothing() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        try await mac.confirm()
        try await phone.poll()
        // The Face ID prompt stays up past the session's expiry.
        let clock = harness.clock
        phone.identity.duringApprovalPrompt = { clock.advance(by: 10 * 60) }
        do {
            try await phone.confirm()
            XCTFail("a confirmation after the session ended is refused")
        } catch DeviceMessengerError.sessionEnded {}
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .expired)
        let phoneDevices = try await phone.devices()
        XCTAssertTrue(phoneDevices.isEmpty)

        // Without a timer having run, confirming an expired session is refused before any prompt.
        let other = harness.makeDevice(.iOS)
        let mac2 = harness.makeDevice(.macOS)
        let qr2 = try await mac2.messenger.startPairing(displayName: "Other Mac")
        try await other.messenger.joinPairing(scannedText: qr2.text, displayName: "Other")
        try await mac2.poll()
        try await other.poll()
        harness.clock.advance(by: 10 * 60)
        do {
            try await other.confirm()
            XCTFail("expired")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        XCTAssertTrue(other.identity.approvalReasons.isEmpty, "no prompt for an expired session")
    }

    func testReplacedSessionCanStillUndoItsResultUntilItExpires() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.delaying(.pairingConfirmation, from: mac.id)
        try await mac.confirm()
        try await phone.confirm()
        try await mac.poll()
        await XCTAssertNotNilAsync(try await mac.entry(for: phone))
        // The Mac starts another pairing, then the phone's person cancels the first one.
        let second = try await mac.messenger.startPairing(displayName: "Studio Mac")
        await phone.messenger.cancelPairing()
        try await mac.poll()
        await XCTAssertNilAsync(try await mac.entry(for: phone), "the retired session undid its result")
        guard case .showingQRCode(second) = await mac.phase() else { return XCTFail("the new session is untouched") }

        // A withdrawal sealed with a retired session's pre-shared key undoes its result too.
        let tablet = harness.makeDevice(.iOS)
        let tabletQR = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await tablet.messenger.joinPairing(scannedText: tabletQR.text, displayName: "Tablet")
        try await mac.poll()
        try await tablet.poll()
        try await mac.poll()
        try await mac.confirm()
        try await tablet.confirm()
        try await mac.poll()
        await XCTAssertNotNilAsync(try await mac.entry(for: tablet))
        _ = try await mac.messenger.startPairing(displayName: "Studio Mac")
        let onlooker = harness.makeDevice(.iOS)
        try await onlooker.messenger.joinPairing(scannedText: tabletQR.text, displayName: "Onlooker")
        await onlooker.messenger.cancelPairing()
        let report = try await mac.poll()
        XCTAssertEqual(report.refusals, [.decryptionFailed], "the onlooker's request does not open with the new session's key")
        await XCTAssertNilAsync(try await mac.entry(for: tablet))
    }

    func testUnpairNoticeFromBeforeARemovalDoesNotEndThePairingThatReplacesIt() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        // The Mac removes the phone; the phone has not fetched the notice when it scans the new code.
        try await mac.messenger.removeDevice(phone.id)
        try await harness.pair(mac, phone)
        let macEntry = try await mac.entry(for: phone)
        let phoneEntry = try await phone.entry(for: mac)
        XCTAssertNotNil(macEntry)
        XCTAssertEqual(phoneEntry?.pairingID, macEntry?.pairingID, "the old notice did not end the new pairing")
        harness.clock.advance(by: 11 * 60)
        let report = try await phone.poll()
        XCTAssertEqual(report.refusals, [], "the held notice was refused as soon as the new entry existed")
        await XCTAssertNotNilAsync(try await phone.entry(for: mac))
    }

    func testHeldMessagesAreRetriedAcrossPagesAndFailedFetchesKeepTheToken() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        harness.transport.delaying(.pairingReveal)
        try await mac.poll()
        try await phone.poll()
        try await phone.confirm()
        harness.transport.releaseDelayed()
        // The phone's confirmation is on the first page and its reveal on the second.
        harness.transport.pageSize = 1
        let report = try await mac.poll()
        XCTAssertEqual(report.processed, 2)
        XCTAssertEqual(report.held, 0)
        guard case .enteringCode = await mac.phase() else { return XCTFail("the reveal arrived on page two") }
        try await mac.confirm()
        guard case .paired = await mac.phase() else { return XCTFail("the held confirmation counted") }

        try await phone.poll()
        let token = await phone.messenger.inboxToken
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let check = try XCTUnwrap(harness.transport.lastSent(.deliveryCheck, from: mac.id))
        harness.transport.failFetches(of: [check.recordName])
        let failed = try await phone.poll()
        XCTAssertEqual(failed.failed, 1)
        await XCTAssertEqualAsync(await phone.messenger.inboxToken, token)
        harness.transport.failFetches(of: [])
        await XCTAssertEqualAsync(try await phone.poll().processed, 1)
    }

    func testCheckLeftPendingByAnEarlierRunBecomesUnanswered() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        mac.restart()
        harness.clock.advance(by: 10 * 60)
        try await mac.poll()
        guard case .noReply = try await mac.entry(for: phone)?.lastDeliveryCheck else {
            return XCTFail("the stored pending check expired")
        }
    }

    func testReplyFromTheReplacedPairingIsRefusedByItsPairingID() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.transport.delaying(.deliveryCheckReply)
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        try await phone.poll()
        harness.transport.interceptor = nil
        harness.clock.advance(by: 30)
        // Pairing again while that check is still pending: the pairing ID tells the reply apart.
        let oldPairing = try await XCTUnwrapAsync(try await mac.entry(for: phone)).pairingID
        try await harness.pair(mac, phone)
        harness.transport.releaseDelayed()
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.bindingMismatch])

        // A reply signed by the phone that answers the check pending now but names the earlier
        // pairing is refused by the payload's pairing ID alone.
        harness.transport.dropping(.deliveryCheck)
        let currentCheck = try await mac.messenger.sendDeliveryCheck(to: phone.id)
        harness.transport.interceptor = nil
        let stale = DeliveryCheckReplyPayload(pairingID: oldPairing, checkMessageID: currentCheck).encoded
        harness.transport.insert(try PairingRuleTests.seal(.deliveryCheckReply, stale, from: phone, to: mac, harness: harness),
                                 intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.bindingMismatch])
        let current = try await XCTUnwrapAsync(try await mac.entry(for: phone)).pairingID
        let genuine = DeliveryCheckReplyPayload(pairingID: current, checkMessageID: currentCheck).encoded
        harness.transport.insert(try PairingRuleTests.seal(.deliveryCheckReply, genuine, from: phone, to: mac, harness: harness),
                                 intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().processed, 1, "the same check with the current pairing ID is answered")
    }

    func testAttackerCannotUseThePhonesCard() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phoneAgreementKey = P256.KeyAgreement.PrivateKey()
        let phone = harness.makeDevice(.iOS, identity: SoftwareDeviceIdentity(
            messageKey: P256.Signing.PrivateKey(), agreementKey: phoneAgreementKey, approvalKey: P256.Signing.PrivateKey()))
        let attacker = SoftwareDeviceIdentity()
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        let phoneCard = try DeviceCard.make(identity: phone.identity, platform: .iOS, createdAt: harness.clock.now())
        // The phone's card in a request the attacker signs.
        let payload = PairingRequestPayload(sessionID: qr.sessionID, card: phoneCard, commitment: Data(repeating: 0, count: 32),
                                            displayName: "Pocket Phone").encoded
        let sentAt = UnixTime.seconds(harness.clock.now())
        let forged = try MessageCodec.seal(kind: .pairingRequest, payload: payload, identity: attacker, recipient: mac.id,
                                           recipientKey: qr.initiatorAgreementKey, preSharedKey: qr.preSharedKey,
                                           sentAt: sentAt, expiresAt: sentAt + 300)
        harness.transport.insert(forged.envelope, intoInboxOf: mac.id)
        await XCTAssertEqualAsync(try await mac.poll().refusals, [.routingMismatch])

        // A card of the attacker's own that claims the phone's key-agreement key: the Mac's
        // challenge is addressed to the attacker, and the phone cannot take it.
        let claimant = harness.makeDevice(.iOS, identity: SoftwareDeviceIdentity(
            messageKey: P256.Signing.PrivateKey(), agreementKey: phoneAgreementKey,
            approvalKey: P256.Signing.PrivateKey()))
        try await claimant.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        guard case .waitingForResponder = await mac.phase() else { return XCTFail("the Mac froze the claimant's request") }
        var challenge = try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.id))
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        harness.transport.insert(challenge, intoInboxOf: phone.id)
        challenge.recipient = phone.id.text
        challenge.recordName = MessageID.random().text
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.wrongRecipient])
        harness.transport.insert(challenge, intoInboxOf: phone.id)
        await XCTAssertEqualAsync(try await phone.poll().refusals, [.decryptionFailed])
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge)
    }

    func testCraftedQRExpiryIsRefusedInsteadOfCrashing() throws {
        let mac = SoftwareDeviceIdentity()
        var bytes = PairingQRPayload(sessionID: PairingSessionID(rawValue: Data(count: 16))!, secret: Data(count: 32),
                                     qrExpiry: Date(timeIntervalSince1970: 1_800_000_000),
                                     initiatorMessageKey: mac.messagePublicKey,
                                     initiatorAgreementKey: mac.agreementPublicKey).bytes
        bytes.replaceSubrange(49..<57, with: Data([0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try PairingQRPayload(text: PairingQRPayload.prefix + Base64URL.encode(bytes))) {
            XCTAssertEqual($0 as? PairingQRPayloadError, .malformed)
        }
        XCTAssertEqual(UnixTime.seconds(Date(timeIntervalSince1970: .greatestFiniteMagnitude)), UnixTime.maximumSeconds)
        XCTAssertEqual(UnixTime.seconds(Date(timeIntervalSince1970: 9.3e18)), UnixTime.maximumSeconds)
        XCTAssertEqual(SecureEnclaveDeviceIdentity.classify(NSError(domain: "com.apple.LocalAuthentication", code: -6)),
                       .authenticationUnavailable)
    }
}

/// A list store whose next save waits until the test opens the gate.
final class GatedListStore: PairedDeviceListStore, @unchecked Sendable {
    private let inner = InMemoryPairedDeviceListStore()
    private let lock = NSLock()
    private var closed = false
    private var waiting = false
    private let gate = DispatchSemaphore(value: 0)

    var isWaiting: Bool { lock.withLock { waiting } }

    func closeGate() { lock.withLock { closed = true } }

    func openGate() { gate.signal() }

    func loadPairedDeviceList() throws -> PairedDeviceList { try inner.loadPairedDeviceList() }

    func savePairedDeviceList(_ list: PairedDeviceList) throws {
        let mustWait = lock.withLock { () -> Bool in
            defer { closed = false }
            if closed { waiting = true }
            return closed
        }
        if mustWait {
            gate.wait()
            lock.withLock { waiting = false }
        }
        try inner.savePairedDeviceList(list)
    }
}
