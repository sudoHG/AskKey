import AskKeyDevicesTestSupport
import AskKeyTestSupport
import Foundation
import XCTest
@testable import AskKeyAppKit
@testable import AskKeyDevices
@testable import AskKeyVault

/// The Mac as pairing initiator (ADR 0013 → Pairing), with software keys,
/// the in-memory transport and a simulated iPhone.
@MainActor
final class DeviceCoordinatorPairingTests: AskKeyAppTestCase {
    private var harness: DeviceCoordinatorHarness!

    override func setUp() async throws {
        harness = try DeviceCoordinatorHarness()
        await harness.coordinator.launch()
    }

    override func tearDown() async throws {
        try harness.close()
        harness = nil
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld, "no test leaves idle expiry held")
    }

    func testFullPairingWhereTheMacConfirmsFirstAndTheIPhoneLater() async throws {
        let coordinator = harness.coordinator
        XCTAssertEqual(coordinator.availability, .ready)
        XCTAssertFalse(coordinator.hasIdentity)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty, "the identity is created on the first pairing")

        let peer = try await harness.startAndScan()
        XCTAssertTrue(coordinator.hasIdentity)
        XCTAssertEqual(peer, PairingPeer(deviceID: harness.phone.deviceID, platform: .iOS, displayName: "Synthetic Phone"))
        XCTAssertEqual(Set(harness.backend.preparedInboxes), [try XCTUnwrap(harness.macDeviceID)],
                       "the Mac prepares its own inbox and subscriptions before the QR code")
        XCTAssertTrue(SessionPolicy.isIdleExpiryHeld, "the open sheet holds idle expiry")
        let expiry = try XCTUnwrap(coordinator.pairingExpiresAt)
        XCTAssertEqual(expiry.timeIntervalSince(harness.clock.now()), 600, accuracy: 1)

        try await harness.phone.poll()
        let shown1 = await harness.phone.shownCode()
        let code = try XCTUnwrap(shown1)
        XCTAssertFalse(harness.script.loggedEvents.contains(.revealVerified))
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .enteringCode(peer: peer, attemptsRemaining: 3))
        XCTAssertTrue(harness.script.loggedEvents.contains(.revealVerified), "the verified reveal is logged without content")

        await coordinator.enterPairingCode(code)
        XCTAssertEqual(coordinator.pairing, .codeAccepted(peer: peer))
        XCTAssertTrue(harness.script.authenticationReasons.isEmpty, "accepting the code asks for nothing")
        XCTAssertTrue(harness.macConfirmations().isEmpty)

        await coordinator.confirmPairing()
        XCTAssertEqual(coordinator.pairing, .waitingForIPhoneConfirmation(peer: peer))
        XCTAssertEqual(harness.script.authenticationReasons, [Vault.devicePairingReason])
        XCTAssertEqual(harness.macConfirmations().count, 1)
        XCTAssertTrue(coordinator.devices.isEmpty, "nothing is added before the iPhone's confirmation")

        // The iPhone confirms later; the Mac adds it without asking again.
        try await harness.phone.confirm()
        try await harness.phone.poll()
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .paired(peer: peer))
        XCTAssertEqual(harness.script.authenticationReasons.count, 1)
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld, "the hold ends with the session")
        let row = try XCTUnwrap(coordinator.devices.first)
        XCTAssertEqual(row.id, harness.phone.deviceID)
        XCTAssertEqual(row.displayName, "Synthetic Phone")
        XCTAssertEqual(row.reachability, .notReachedYet)
        let phoneEntries = try await harness.phone.pairedDevices()
        XCTAssertEqual(phoneEntries.map(\.deviceID), [try XCTUnwrap(harness.macDeviceID)])
        XCTAssertEqual(harness.macSent(.deliveryCheck).count, 1, "a delivery check follows the pairing")

        for text in [code, code.replacingOccurrences(of: " ", with: "")] {
            XCTAssertFalse(harness.publishedState().contains(text), "the coordinator never exposes the code")
        }
    }

    func testNoCodeEntryBeforeTheRevealAndAMismatchedRevealStoresNothing() async throws {
        let coordinator = harness.coordinator
        harness.transport.interceptor = { envelope in
            envelope.kind == Int64(MessageKind.pairingReveal.rawValue) ? .drop : .deliver
        }
        let peer = try await harness.startAndScan()
        try await harness.phone.poll()
        let shown2 = await harness.phone.shownCode()
        let code = try XCTUnwrap(shown2, "the iPhone shows a code; its reveal was lost")
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .waitingForIPhone(peer: peer, since: harness.clock.now()))

        await coordinator.enterPairingCode(code)
        XCTAssertNil(coordinator.pairingFeedback)
        guard case .waitingForIPhone = coordinator.pairing else { return XCTFail("no code entry before the reveal") }
        await XCTAssertThrowsErrorAsync(try await harness.coordinator.services!.messenger.enterPairingCode(code))

        // A reveal bound to the challenge but with another secret.
        harness.transport.interceptor = nil
        let mac = try XCTUnwrap(harness.macDeviceID)
        let challengeEnvelope = try XCTUnwrap(harness.transport.sentEnvelopes.last {
            $0.kind == Int64(MessageKind.pairingChallenge.rawValue) && $0.sender == mac.text
        })
        let challenge = try DeviceCoordinatorHarness.open(challengeEnvelope, by: harness.phone.identity, now: harness.clock.now())
        let challengePayload = try PairingChallengePayload(decoding: challenge.payload)
        let card = challengePayload.card
        let forged = PairingRevealPayload(sessionID: challengePayload.sessionID, challengeDigest: challenge.digest,
                                          secret: RandomBytes.make(32))
        let sentAt = UnixTime.seconds(harness.clock.now())
        let sealed = try MessageCodec.seal(kind: .pairingReveal, payload: forged.encoded, identity: harness.phone.identity,
                                           recipient: mac, recipientKey: card.agreementPublicKey, preSharedKey: nil,
                                           sentAt: sentAt, expiresAt: sentAt + 300)
        harness.transport.insert(sealed.envelope, intoInboxOf: mac)
        await coordinator.refresh()

        XCTAssertEqual(coordinator.pairing, .ended(.commitmentMismatch))
        XCTAssertTrue(coordinator.devices.isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices], "nothing is stored")
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)
        XCTAssertTrue(harness.macConfirmations().isEmpty)
    }

    func testCancelledAuthenticationSendsNothingAndARetryNeedsNoNewEntry() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        await coordinator.enterPairingCode(code)
        harness.script.authenticationResults = [.cancelled, .failed]

        await coordinator.confirmPairing()
        XCTAssertEqual(coordinator.pairingFeedback, .authenticationCancelled)
        guard case .codeAccepted = coordinator.pairing else { return XCTFail("the accepted code stays accepted") }
        XCTAssertTrue(harness.macConfirmations().isEmpty, "a cancelled authentication sends nothing")
        await coordinator.confirmPairing()
        XCTAssertEqual(coordinator.pairingFeedback, .authenticationFailed)
        XCTAssertTrue(harness.macConfirmations().isEmpty, "a failed authentication sends nothing")
        guard case .codeAccepted = coordinator.pairing else { return XCTFail("neither prompt counted as an attempt") }

        await coordinator.confirmPairing()
        XCTAssertNil(coordinator.pairingFeedback)
        XCTAssertEqual(harness.macConfirmations().count, 1, "the retry sends the confirmation without a new entry")
        XCTAssertEqual(harness.script.authenticationReasons.count, 3)
        guard case .waitingForIPhoneConfirmation = coordinator.pairing else { return XCTFail("the Mac confirmed") }
    }

    func testAuthenticationThatCompletesAfterTheSessionEndedSendsNothing() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        await coordinator.enterPairingCode(code)
        let clock = harness.clock
        harness.script.duringAuthentication = { clock.advance(by: 11 * 60) }

        await coordinator.confirmPairing()

        XCTAssertTrue(harness.macConfirmations().isEmpty)
        XCTAssertEqual(coordinator.pairing, .ended(.expired))
        try? await harness.phone.confirm()
        await coordinator.refresh()
        XCTAssertTrue(coordinator.devices.isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
    }

    func testAuthenticationThatCompletesAfterCancelSendsNothing() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        await coordinator.enterPairingCode(code)
        harness.script.duringAuthentication = { [coordinator] in await coordinator.cancelPairing() }

        await coordinator.confirmPairing()

        XCTAssertTrue(harness.macConfirmations().isEmpty)
        XCTAssertNil(coordinator.pairing)
        XCTAssertEqual(harness.macSent(.pairingCancellation).count, 1, "the iPhone is told")
    }

    func testThreeWrongCodesEndTheSessionWithNothingStored() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        let digits = code.replacingOccurrences(of: " ", with: "")
        let wrong = String(format: "%06d", (Int(digits)! + 1) % 1_000_000)

        await coordinator.enterPairingCode("12 34")
        XCTAssertEqual(coordinator.pairingFeedback, .invalidCodeFormat)
        await coordinator.enterPairingCode(wrong)
        XCTAssertEqual(coordinator.pairingFeedback, .wrongCode(attemptsRemaining: 2))
        guard case .enteringCode(_, 2) = coordinator.pairing else { return XCTFail("two attempts left") }
        await coordinator.enterPairingCode(wrong)
        await coordinator.enterPairingCode(wrong)

        XCTAssertEqual(coordinator.pairing, .ended(.codeMismatch))
        XCTAssertEqual(harness.macSent(.pairingCancellation).count, 1)
        XCTAssertTrue(harness.script.authenticationReasons.isEmpty)
        XCTAssertTrue(harness.macConfirmations().isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
        XCTAssertFalse(harness.publishedState().contains(digits))
    }

    func testCancelExpiryAndASecondRequestEndTheSessionWithNothingStored() async throws {
        let coordinator = harness.coordinator
        // Cancel.
        _ = try await harness.startAndScan()
        await coordinator.cancelPairing()
        XCTAssertNil(coordinator.pairing)
        XCTAssertEqual(harness.macSent(.pairingCancellation).count, 1)
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)

        // Expiry.
        await coordinator.startPairing()
        harness.clock.advance(by: 11 * 60)
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .ended(.expired))
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)

        // A second request for the same QR code.
        await coordinator.startPairing()
        guard case .showingQRCode(let text, _) = coordinator.pairing else { return XCTFail("a new QR code") }
        let other = SimulatedPairingPhone(transport: harness.transport, clock: harness.clock)
        try await harness.phone.scan(text)
        try await other.scan(text, name: "Synthetic Other Phone")
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .ended(.secondRequest))

        XCTAssertTrue(coordinator.devices.isEmpty)
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
        XCTAssertTrue(harness.script.authenticationReasons.isEmpty)
    }

    func testIPhoneWithdrawalWithoutChallengeEndsTheSession() async throws {
        let coordinator = harness.coordinator
        harness.transport.interceptor = { envelope in
            envelope.kind == Int64(MessageKind.pairingRequest.rawValue) ? .delay : .deliver
        }
        await coordinator.startPairing()
        guard case .showingQRCode(let text, _) = coordinator.pairing else { return XCTFail("a QR code") }
        try await harness.phone.scan(text)
        harness.clock.advance(by: 61)
        try await harness.phone.poll()
        harness.transport.interceptor = nil
        await coordinator.refresh()
        XCTAssertEqual(coordinator.pairing, .ended(.cancelledByPeer))
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
    }

    func testCancellationAfterTheMacAddedTheDeviceRemovesIt() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        try await harness.phone.confirm()
        await coordinator.enterPairingCode(code)
        await coordinator.confirmPairing()
        await coordinator.refresh()
        guard case .paired = coordinator.pairing else { return XCTFail("the Mac added the iPhone") }
        XCTAssertEqual(coordinator.devices.count, 1)

        await harness.phone.cancel()
        await coordinator.refresh()

        XCTAssertEqual(coordinator.pairing, .ended(.undoneByPeer))
        XCTAssertTrue(coordinator.devices.isEmpty)
        let stored = try await harness.library.vault.pairedDeviceRegistry().list()
        XCTAssertTrue(stored.devices.isEmpty)
    }

    func testLockingManagementCancelsTheSessionAndStopsTheAdd() async throws {
        let coordinator = harness.coordinator
        let code = try await harness.reachCodeEntry()
        await coordinator.enterPairingCode(code)
        await coordinator.confirmPairing()
        XCTAssertEqual(harness.macConfirmations().count, 1)

        harness.script.managementActive = false
        harness.library.vault.endManagementSession()
        await coordinator.managementSessionEnded()
        XCTAssertNil(coordinator.pairing)
        XCTAssertEqual(harness.macSent(.pairingCancellation).count, 1)

        try await harness.phone.confirm()
        await coordinator.refresh()
        XCTAssertTrue(coordinator.devices.isEmpty, "the authorization did not outlive the management session")
        XCTAssertNil(harness.library.keys.deviceItems[.pairedDevices])
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)
    }

    func testPairingTickCancelsWhenTheManagementSessionIsGone() async throws {
        _ = try await harness.startAndScan()
        harness.script.managementActive = false
        await harness.coordinator.pairingTick()
        XCTAssertNil(harness.coordinator.pairing)
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)
    }

    func testPairingNeedsTheManagementSessionAndAnAvailableAccountBeforeAnyKeyIsStored() async throws {
        let coordinator = harness.coordinator
        harness.script.managementActive = false
        await coordinator.startPairing()
        XCTAssertEqual(coordinator.pairing, .failed(.managementRequired))
        harness.script.managementActive = true

        harness.backend.accountState = .noAccount
        await coordinator.startPairing()
        XCTAssertEqual(coordinator.pairing, .failed(.accountUnavailable(.noAccount)))
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty, "no key is stored without an account")
        XCTAssertFalse(coordinator.hasIdentity)
        XCTAssertFalse(SessionPolicy.isIdleExpiryHeld)

        harness.backend.accountState = .available(userRecordName: "_synthetic-account-1")
        harness.backend.isSecureEnclaveAvailable = false
        await coordinator.startPairing()
        XCTAssertEqual(coordinator.pairing, .failed(.secureEnclaveUnavailable))
        XCTAssertEqual(coordinator.availability, .secureEnclaveUnavailable)
        XCTAssertTrue(harness.library.keys.deviceItems.isEmpty)
    }

    func testOpenPairingSheetHoldsIdleExpiryAndClosingItRestoresTheNormalExpiry() async throws {
        var timers: [(timeout: Double, timer: Timer)] = []
        let policy = SessionPolicy(scheduleTimer: { timeout, callback in
            let timer = Timer(timeInterval: timeout, repeats: false, block: callback)
            timers.append((timeout, timer))
            return timer
        }, enqueueExpiration: { callback in
            MainActor.assumeIsolated { callback() }
        })
        defer { policy.cancel() }
        var expired = 0
        policy.renew(timeout: 300) { expired += 1 }

        _ = try await harness.startAndScan()
        timers[0].timer.fire()
        XCTAssertEqual(expired, 0, "an open pairing sheet keeps the management session from expiring")
        XCTAssertEqual(timers.count, 1)

        await harness.coordinator.cancelPairing()
        XCTAssertEqual(timers.count, 2, "closing the sheet restarts the normal timeout")
        XCTAssertEqual(timers[1].timeout, 300)
        XCTAssertEqual(expired, 0)
        timers[1].timer.fire()
        XCTAssertEqual(expired, 1)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error \(message)", file: file, line: line)
    } catch {}
}
