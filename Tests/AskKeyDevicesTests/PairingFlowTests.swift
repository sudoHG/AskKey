import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

final class PairingFlowTests: XCTestCase {
    func testFullPairingGivesBothSidesTheSameCodeCardsAndPairingIDAndMessagesRoundTrip() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)

        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        guard case .showingQRCode(let shown) = await mac.phase() else { return XCTFail("the Mac shows the QR code") }
        XCTAssertEqual(shown, qr)
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge)
        await XCTAssertNilAsync(await phone.code(), "no code before the challenge")

        try await mac.poll()
        guard case .waitingForResponder(let phoneSummary) = await mac.phase() else {
            return XCTFail("the Mac hides the QR code and waits for the phone once it froze the request")
        }
        XCTAssertEqual(phoneSummary, PairingPeer(deviceID: phone.id, platform: .iOS, displayName: "Pocket Phone"))
        await XCTAssertNilAsync(await mac.derivedCode(), "no code before the reveal")
        try await phone.poll()
        guard case .showingCode(let phoneCode, let macSummary, confirmed: false) = await phone.phase() else {
            return XCTFail("the phone shows the code once it sent its reveal")
        }
        XCTAssertNotNil(harness.transport.lastSent(.pairingReveal, from: phone.id))
        XCTAssertEqual(macSummary, PairingPeer(deviceID: mac.id, platform: .macOS, displayName: "Studio Mac"))
        try await mac.poll()
        guard case .enteringCode(phoneSummary, attemptsRemaining: 3) = await mac.phase() else {
            return XCTFail("the Mac asks for the code once the reveal matched the commitment")
        }
        await XCTAssertEqualAsync(await mac.derivedCode(), phoneCode, "both sides derive the same code")
        XCTAssertEqual(phoneCode.formatted.count, 7)

        try await phone.messenger.confirmPairing(approvalReason: "Pair with Studio Mac")
        guard case .showingCode(phoneCode, _, confirmed: true) = await phone.phase() else {
            return XCTFail("the phone keeps showing the code until the Mac confirms")
        }
        try await mac.poll()
        guard case .enteringCode = await mac.phase() else {
            return XCTFail("until the person confirms, the Mac does not show that the phone confirmed")
        }
        try await mac.messenger.enterPairingCode(phoneCode.formatted)
        guard case .codeAccepted = await mac.phase() else { return XCTFail("the Mac accepted the code") }
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty, "accepting the code signs nothing")
        try await mac.messenger.confirmPairing(approvalReason: "Pair with Pocket Phone")
        try await phone.poll()
        XCTAssertEqual(phone.identity.approvalReasons, ["Pair with Studio Mac"])
        XCTAssertEqual(mac.identity.approvalReasons, ["Pair with Pocket Phone"])

        let macPairing = try await XCTUnwrapAsync(await mac.pairingID())
        await XCTAssertEqualAsync(await phone.pairingID(), macPairing)
        let macEntry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        let phoneEntry = try await XCTUnwrapAsync(try await phone.entry(for: mac))
        XCTAssertEqual(macEntry.card.compressedPublicKeys, [phone.identity.messagePublicKey.compressedRepresentation,
                                                           phone.identity.agreementPublicKey.compressedRepresentation,
                                                           phone.identity.approvalPublicKey.compressedRepresentation])
        XCTAssertEqual(phoneEntry.card.deviceID, mac.id)
        XCTAssertEqual(macEntry.pairingID, macPairing)
        XCTAssertEqual(phoneEntry.pairingID, macPairing)
        XCTAssertEqual(macEntry.displayName, "Pocket Phone")
        XCTAssertEqual(phoneEntry.platform, .macOS)
        XCTAssertFalse(macEntry.isReached)
        XCTAssertFalse(phoneEntry.isReached, "both sides show not reached yet")

        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        try await phone.poll()
        try await mac.poll()
        await XCTAssertTrueAsync(try await XCTUnwrapAsync(try await mac.entry(for: phone)).isReached)
        await XCTAssertTrueAsync(try await XCTUnwrapAsync(try await phone.entry(for: mac)).isReached)
        guard case .replied = try await XCTUnwrapAsync(try await mac.entry(for: phone)).lastDeliveryCheck else {
            return XCTFail("the Mac records the reply")
        }

        try await phone.messenger.sendDeliveryCheck(to: mac.id)
        try await mac.poll()
        let report = try await phone.poll()
        XCTAssertEqual(report.processed, 1)
        guard case .replied = try await XCTUnwrapAsync(try await phone.entry(for: mac)).lastDeliveryCheck else {
            return XCTFail("the reverse direction round-trips too")
        }
    }

    func testAttackerWithTheQRCodeAndThePhonesCardCannotMakeTheCodesMatch() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let attacker = harness.makeDevice(.iOS)

        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        // A writer to the account deletes the real phone's request before the Mac fetches it.
        let realRequest = try XCTUnwrap(harness.transport.lastSent(.pairingRequest, from: phone.id))
        harness.transport.deleteRecord(named: realRequest.recordName, from: mac.id)
        // It holds the real phone's card and can open nothing the phone sealed, so it sends its own request.
        try await attacker.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.frozenPeer()?.deviceID, attacker.id, "the Mac froze the only request it saw")
        try await attacker.poll()
        try await mac.poll()
        let macCode = try await XCTUnwrapAsync(await mac.derivedCode())
        guard case .enteringCode = await mac.phase() else {
            return XCTFail("the Mac asks for a code and exposes none")
        }
        await XCTAssertEqualAsync(await attacker.code(), macCode, "only the device whose card was frozen gets the code")

        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase(), .waitingForChallenge, "the real phone receives no challenge and shows no code")
        // The challenge the Mac sealed for the attacker, copied into the phone's inbox, is refused.
        let challenge = try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.id))
        harness.transport.insert(challenge, intoInboxOf: phone.id)
        let report = try await phone.poll()
        XCTAssertEqual(report.refusals, [.wrongRecipient])
        await XCTAssertNilAsync(await phone.code())

        // After 60 seconds the phone withdraws and warns; the Mac's session ends with nothing stored.
        harness.clock.advance(by: 61)
        await phone.messenger.advanceTimers()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .noChallenge)
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .cancelledByPeer)
        try await attacker.poll()
        await XCTAssertEqualAsync(await attacker.phase()?.endReason, .cancelledByPeer, "the Mac cancels toward the peer it knew")
        for device in [mac, phone, attacker] {
            let devices = try await device.devices()
            XCTAssertTrue(devices.isEmpty)
        }
    }

    func testRequestSealedWithoutTheQRSecretLeavesBothListsUnchanged() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        // Same keys and expiry, a different pairing secret.
        let forged = PairingQRPayload(sessionID: qr.sessionID, secret: Data(repeating: 7, count: 32), qrExpiry: qr.qrExpiry,
                                      initiatorMessageKey: qr.initiatorMessageKey,
                                      initiatorAgreementKey: qr.initiatorAgreementKey)
        try await phone.messenger.joinPairing(scannedText: forged.text, displayName: "Pocket Phone")
        let report = try await mac.poll()
        XCTAssertEqual(report.refusals, [.decryptionFailed])
        guard case .showingQRCode = await mac.phase() else { return XCTFail("nothing is frozen") }
        try await assertNoTrust(mac, phone)
    }

    func testSecondRequestEndsTheSessionWithNothingStored() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let other = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await other.messenger.joinPairing(scannedText: qr.text, displayName: "Other Phone")
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .secondRequest)
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .cancelledByPeer, "the frozen requester is told")
        try await assertNoTrust(mac, phone)
        try await assertNoTrust(mac, other)
    }

    func testExpiredSessionLeavesBothListsUnchanged() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await phone.confirm()
        harness.clock.advance(by: 10 * 60)
        try await mac.poll()
        do {
            try await mac.confirm()
            XCTFail("an expired session cannot be confirmed")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        try await phone.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .expired)
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .expired)
        try await assertNoTrust(mac, phone)

        let late = harness.makeDevice(.iOS)
        do {
            try await late.messenger.joinPairing(scannedText: qr.text, displayName: "Late Phone")
            XCTFail("an expired QR code is refused")
        } catch PairingQRPayloadError.expired {}
    }

    func testCancellationOnEitherSideLeavesBothListsUnchanged() async throws {
        for step in ["mac cancels", "phone cancels", "phone cancels before challenge"] {
            let harness = DeviceHarness()
            let mac = harness.makeDevice(.macOS)
            let phone = harness.makeDevice(.iOS)
            let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
            try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
            if step == "phone cancels before challenge" {
                await phone.messenger.cancelPairing()
                try await mac.poll()
                await XCTAssertEqualAsync(await mac.phase()?.endReason, .cancelledByPeer, "a PSK-mode withdrawal ends the Mac's session")
                try await assertNoTrust(mac, phone)
                continue
            }
            try await mac.poll()
            try await phone.poll()
            try await mac.poll()
            if step == "mac cancels" {
                await mac.messenger.cancelPairing()
            } else {
                await phone.messenger.cancelPairing()
            }
            // The other side confirms anyway; nothing is trusted.
            if step.hasPrefix("mac") {
                try await phone.confirm()
            } else {
                try await mac.confirm()
            }
            try await mac.poll()
            try await phone.poll()
            let ended = step.hasPrefix("mac") ? await mac.phase() : await phone.phase()
            XCTAssertEqual(ended?.endReason, .cancelled, step)
            let other = step.hasPrefix("mac") ? await phone.phase() : await mac.phase()
            XCTAssertEqual(other?.endReason, .cancelledByPeer, step)
            try await assertNoTrust(mac, phone)
        }
    }

    func testCancelledFaceIDSendsNothing() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        phone.identity.approvalBehavior = .cancel
        do {
            try await phone.confirm()
            XCTFail("a cancelled prompt throws")
        } catch DeviceIdentityError.authenticationCancelled {}
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: phone.id))
        guard case .showingCode(_, _, confirmed: false) = await phone.phase() else {
            return XCTFail("the phone can still confirm or cancel")
        }
        phone.identity.approvalBehavior = .sign
        try await phone.confirm()
        XCTAssertEqual(phone.identity.approvalReasons.count, 2, "every confirmation asks again")
    }

    func testSideThatConfirmedAloneDoesNotTrustAndBothShowNotReachedYet() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.dropping(.pairingConfirmation, from: mac.id)
        try await phone.confirm()
        try await mac.confirm()
        try await mac.poll()
        try await phone.poll()
        guard case .paired = await mac.phase() else { return XCTFail("the Mac holds both confirmations") }
        guard case .showingCode(_, _, confirmed: true) = await phone.phase() else {
            return XCTFail("the phone still waits for the Mac")
        }
        harness.clock.advance(by: 10 * 60)
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .expired)
        let phoneDevices = try await phone.devices()
        XCTAssertTrue(phoneDevices.isEmpty, "the phone never trusts a Mac whose confirmation never arrived")

        let macEntry = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        XCTAssertFalse(macEntry.isReached, "the half-paired Mac shows not reached yet")
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let phoneReport = try await phone.poll()
        XCTAssertEqual(phoneReport.refusals, [.unknownSender])
        try await mac.poll()
        harness.clock.advance(by: 10 * 60)
        try await mac.poll()
        let after = try await XCTUnwrapAsync(try await mac.entry(for: phone))
        XCTAssertFalse(after.isReached)
        guard case .noReply = after.lastDeliveryCheck else { return XCTFail("the check is recorded as unanswered") }
    }

    func testSideThatAddedThePeerRemovesItOnACancellationForThatSession() async throws {
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
        await XCTAssertNotNilAsync(try await mac.entry(for: phone), "the Mac added the phone")
        // The person cancels on the phone before the Mac's confirmation arrives.
        await phone.messenger.cancelPairing()
        harness.transport.interceptor = nil
        harness.transport.releaseDelayed()
        try await phone.poll()
        try await mac.poll()
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .undoneByPeer)
        try await assertNoTrust(mac, phone)
    }

    func testPhoneThatAddedTheMacRemovesItWhenTheMacCancels() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.delaying(.pairingConfirmation, from: phone.id)
        try await mac.confirm()
        try await phone.confirm()
        try await phone.poll()
        guard case .paired = await phone.phase() else { return XCTFail("the phone holds both confirmations") }
        await mac.messenger.cancelPairing()
        harness.transport.releaseDelayed()
        try await mac.poll()
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .undoneByPeer)
        try await assertNoTrust(mac, phone)
    }

    func testAnyoneWithTheQRCodeCanUndoTheResultButNotRestoreAReplacedEntry() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        try await harness.pair(mac, phone)
        harness.clock.advance(by: 11 * 60)
        // Pairing again replaces the entry; a QR holder then withdraws within the new session.
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        try await mac.confirm()
        try await phone.confirm()
        try await mac.poll()
        guard case .paired = await mac.phase() else { return XCTFail("the Mac added the phone again") }
        let onlooker = harness.makeDevice(.iOS)
        try await onlooker.messenger.joinPairing(scannedText: qr.text, displayName: "Onlooker")
        await onlooker.messenger.cancelPairing()
        let report = try await mac.poll()
        XCTAssertEqual(report.refusals, [.bindingMismatch], "a second request after the peer was added is ignored")
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .undoneByPeer)
        let macEntry = try await mac.entry(for: phone)
        XCTAssertNil(macEntry, "the entry the first pairing wrote is not restored")
    }

    func testEarlyDeliveryCheckFromTheSessionPeerIsHeldUntilThePeerIsAdded() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        harness.transport.delaying(.pairingConfirmation, from: mac.id)
        try await phone.confirm()
        try await mac.confirm()
        try await mac.poll()
        try await mac.messenger.sendDeliveryCheck(to: phone.id)
        let early = try await phone.poll()
        XCTAssertEqual(early.held, 1, "the check overtook the Mac's confirmation")
        harness.transport.releaseDelayed()
        let later = try await phone.poll()
        XCTAssertEqual(later.processed, 2)
        try await mac.poll()
        await XCTAssertTrueAsync(try await XCTUnwrapAsync(try await mac.entry(for: phone)).isReached)
    }

    private func assertNoTrust(_ first: SimulatedDevice, _ second: SimulatedDevice,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let firstEntry = try await first.entry(for: second)
        let secondEntry = try await second.entry(for: first)
        XCTAssertNil(firstEntry, file: file, line: line)
        XCTAssertNil(secondEntry, file: file, line: line)
    }
}
