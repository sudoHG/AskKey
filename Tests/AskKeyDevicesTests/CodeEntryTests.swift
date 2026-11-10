@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// #282, decision 5, and ADR 0013 → Pairing, steps 4 to 6: the iPhone shows
/// the code, the person enters it on the Mac, and the Mac confirms only
/// while its session is open and holds an accepted entry.
final class CodeEntryTests: XCTestCase {
    func testTheRightCodeIsAcceptedAndThenConfirmedWithOneApprovalPrompt() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        guard case .codeAccepted(let peer) = await mac.phase() else { return XCTFail("the Mac accepted the code") }
        XCTAssertEqual(peer.deviceID, phone.id)
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty, "accepting the code signs nothing")
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))
        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        XCTAssertEqual(mac.identity.approvalReasons, ["Pair"])
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the Mac waits for the phone") }
        XCTAssertNotNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))
        try await phone.messenger.confirmPairing(approvalReason: "Pair")
        try await mac.poll()
        try await phone.poll()
        try await assertPaired(mac, phone)
    }

    func testOneOrTwoWrongCodesLeaveAttemptsAndTheRightCodeStillPairs() async throws {
        for wrongCount in 1...2 {
            let (harness, mac, phone) = try await startedSession()
            let code = try await XCTUnwrapAsync(await phone.code())
            for attempt in 1...wrongCount {
                do {
                    try await mac.messenger.enterPairingCode(Self.wrong(code))
                    XCTFail("a wrong code is refused")
                } catch DeviceMessengerError.wrongCode(let remaining) {
                    XCTAssertEqual(remaining, 3 - attempt)
                }
                guard case .enteringCode(_, let left) = await mac.phase() else { return XCTFail("still entering") }
                XCTAssertEqual(left, 3 - attempt)
            }
            XCTAssertNil(harness.transport.lastSent(.pairingCancellation, from: mac.id))
            try await mac.messenger.enterPairingCode(code.formatted)
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            try await phone.messenger.confirmPairing(approvalReason: "Pair")
            try await mac.poll()
            try await phone.poll()
            try await assertPaired(mac, phone)
            XCTAssertEqual(mac.identity.approvalReasons.count, 1, "wrong codes never reach the approval key")
        }
    }

    func testThirdWrongCodeEndsTheSessionAndCancelsOnThePhone() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        // The phone confirmed first; it still trusts nothing without the Mac.
        try await phone.messenger.confirmPairing(approvalReason: "Pair")
        try await mac.poll()
        var remaining: [Int] = []
        for _ in 1...3 {
            do {
                try await mac.messenger.enterPairingCode(Self.wrong(code))
            } catch DeviceMessengerError.wrongCode(let left) {
                remaining.append(left)
            }
        }
        XCTAssertEqual(remaining, [2, 1, 0])
        let endedPhase = await mac.phase()
        XCTAssertEqual(endedPhase?.endReason, .codeMismatch)
        XCTAssertFalse(Self.contains(code, in: endedPhase as Any), "the ended session shows no code")
        XCTAssertNotNil(harness.transport.lastSent(.pairingCancellation, from: mac.id), "a signed cancellation")
        for attempt in ["enter", "confirm"] {
            do {
                if attempt == "enter" {
                    try await mac.messenger.enterPairingCode(code.formatted)
                } else {
                    try await mac.messenger.confirmPairing(approvalReason: "Pair")
                }
                XCTFail("the ended session takes nothing: \(attempt)")
            } catch DeviceMessengerError.notAwaitingConfirmation {}
        }
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .cancelledByPeer)
        await XCTAssertNilAsync(try await mac.entry(for: phone))
        await XCTAssertNilAsync(try await phone.entry(for: mac))
    }

    func testMalformedCodesAreRefusedWithoutCountingAnAttempt() async throws {
        let (_, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        do {
            try await mac.messenger.enterPairingCode(Self.wrong(code))
            XCTFail("a wrong code is refused")
        } catch DeviceMessengerError.wrongCode(attemptsRemaining: 2) {}
        let malformed = ["", "12345", "1234567", "12a456", "12-345", "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}",
                         "\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}", "123\u{200B}456",
                         String(code.digits.dropLast()) + "\u{2460}"]
        for text in malformed {
            do {
                try await mac.messenger.enterPairingCode(text)
                XCTFail("\(text.debugDescription) is not six ASCII digits")
            } catch DeviceMessengerError.invalidCodeFormat {}
        }
        guard case .enteringCode(_, attemptsRemaining: 2) = await mac.phase() else {
            return XCTFail("malformed input does not count")
        }
        try await mac.messenger.enterPairingCode(code.digits)
        guard case .codeAccepted = await mac.phase() else { return XCTFail("the right code is still accepted") }
    }

    func testWhiteSpaceInTheTypedCodeIsIgnored() async throws {
        let entries = ["012 345", " 012345 ", "0 1 2 3 4 5", "012\t345", "012\n345", "012\u{00A0}345", "012\u{202F}345",
                       "012\u{3000}345"]
        for text in entries {
            let entered = try XCTUnwrap(EnteredPairingCode(text), text.debugDescription)
            XCTAssertTrue(PairingCode(value: 12345).matches(entered), text.debugDescription)
        }
        XCTAssertFalse(PairingCode(value: 12346).matches(try XCTUnwrap(EnteredPairingCode("012345"))))
        XCTAssertFalse(PairingCode(value: 12345).matches(try XCTUnwrap(EnteredPairingCode("12345 0"))))

        let (_, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode("  \(code.formatted)\u{3000}")
        guard case .codeAccepted = await mac.phase() else { return XCTFail("the code as the phone shows it is accepted") }
    }

    func testTheMacNeverExposesTheCodeAndPrintingNeverRevealsIt() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        var macPhases: [PairingPhase?] = []
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        macPhases.append(await mac.phase())
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        macPhases.append(await mac.phase())
        try await phone.poll()
        try await mac.poll()
        macPhases.append(await mac.phase())
        let code = try await XCTUnwrapAsync(await phone.code())
        let showing = await phone.phase()
        do {
            try await mac.messenger.enterPairingCode(Self.wrong(code))
            XCTFail("a wrong code is refused")
        } catch DeviceMessengerError.wrongCode(attemptsRemaining: 2) {}
        macPhases.append(await mac.phase())
        try await mac.messenger.enterPairingCode(code.digits)
        macPhases.append(await mac.phase())
        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        macPhases.append(await mac.phase())
        try await phone.messenger.confirmPairing(approvalReason: "Pair")
        try await mac.poll()
        try await phone.poll()
        macPhases.append(await mac.phase())

        XCTAssertEqual(macPhases.compactMap { $0.map(Self.caseName) },
                       ["showingQRCode", "waitingForResponder", "enteringCode", "enteringCode", "codeAccepted",
                        "waitingForPeer", "paired"])
        for phase in macPhases {
            XCTAssertFalse(Self.contains(code, in: phase as Any), "\(String(describing: phase)) carries no code")
        }
        let phonePhase = await phone.phase()
        guard case .paired = phonePhase else { return XCTFail("the phone paired") }
        XCTAssertFalse(Self.contains(code, in: phonePhase as Any), "the paired phone no longer shows it")

        // Only `formatted` and `digits` show the code; printing a phase does not.
        var dumped = ""
        dump(showing, to: &dumped)
        for printed in ["\(code)", String(reflecting: code), String(describing: showing), dumped] {
            XCTAssertFalse(printed.contains(code.digits) || printed.contains(code.formatted), printed)
        }
    }

    func testOnlyTheMacEntersACodeAndItConfirmsOnlyWithAnAcceptedOne() async throws {
        let (harness, mac, phone) = try await startedSession()
        do {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("the Mac cannot confirm without an accepted code")
        } catch DeviceMessengerError.codeRequired {}
        let code = try await XCTUnwrapAsync(await phone.code())
        do {
            try await phone.messenger.enterPairingCode(code.digits)
            XCTFail("the phone has no code to enter")
        } catch DeviceMessengerError.wrongRole {}
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id), "nothing was sent")

        try await phone.messenger.confirmPairing(approvalReason: "Pair with Studio Mac")
        XCTAssertEqual(phone.identity.approvalReasons, ["Pair with Studio Mac"], "Face ID once, no code")
        XCTAssertNotNil(harness.transport.lastSent(.pairingConfirmation, from: phone.id))
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else {
            return XCTFail("the Mac is unaffected")
        }
        try await mac.messenger.enterPairingCode(code.digits)
        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        try await mac.poll()
        try await phone.poll()
        try await assertPaired(mac, phone)
    }

    func testFailedAuthenticationKeepsTheAcceptedCodeAndCanBeRetriedWithoutTyping() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        for behavior in [SoftwareDeviceIdentity.ApprovalBehavior.cancel, .fail] {
            mac.identity.approvalBehavior = behavior
            do {
                try await mac.messenger.confirmPairing(approvalReason: "Pair")
                XCTFail("the prompt did not sign")
            } catch let error as DeviceIdentityError {
                XCTAssertTrue([.authenticationCancelled, .authenticationFailed].contains(error))
            }
            XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id), "nothing was sent")
            guard case .codeAccepted = await mac.phase() else { return XCTFail("still accepted, not an attempt") }
        }
        mac.identity.approvalBehavior = .sign
        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        XCTAssertEqual(mac.identity.approvalReasons.count, 3)
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the retry confirms") }
    }

    func testEntryAfterAnAcceptedCodeIsRefusedWithoutCounting() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        for text in [Self.wrong(code), Self.wrong(code), Self.wrong(code), code.digits] {
            do {
                try await mac.messenger.enterPairingCode(text)
                XCTFail("the session already accepted a code")
            } catch DeviceMessengerError.codeAlreadyAccepted {}
        }
        guard case .codeAccepted = await mac.phase() else { return XCTFail("further entries count nothing") }
        XCTAssertNil(harness.transport.lastSent(.pairingCancellation, from: mac.id))
        try await mac.messenger.confirmPairing(approvalReason: "Pair")
        do {
            try await mac.messenger.enterPairingCode(code.digits)
            XCTFail("the Mac confirmed")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the confirmation stands") }
    }

    func testMacConfirmationNeedsAnOpenSessionWithAnAcceptedCode() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        for attempt in ["enter", "confirm"] {
            do {
                if attempt == "enter" {
                    try await mac.messenger.enterPairingCode("123456")
                } else {
                    try await mac.messenger.confirmPairing(approvalReason: "Pair")
                }
                XCTFail("no session: \(attempt)")
            } catch DeviceMessengerError.notAwaitingConfirmation {}
        }
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        do {
            try await mac.messenger.enterPairingCode("123456")
            XCTFail("no request frozen yet")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        harness.clock.advance(by: 10 * 60)
        do {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("the session expired")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .expired)
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty, "no prompt")
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id), "nothing was sent")
    }

    func testSessionEndingDuringTheMacsApprovalPromptSendsNothing() async throws {
        // The prompt outlasts the session.
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        let clock = harness.clock
        mac.identity.duringApprovalPrompt = { clock.advance(by: 10 * 60) }
        do {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("the session expired during the prompt")
        } catch DeviceMessengerError.sessionEnded {}
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .expired)

        // The person cancels while the prompt is open.
        let (other, mac2, phone2) = try await startedSession()
        let code2 = try await XCTUnwrapAsync(await phone2.code())
        try await mac2.messenger.enterPairingCode(code2.digits)
        let result = await whileApprovalPromptIsOpen(on: mac2, confirming: {
            try await mac2.messenger.confirmPairing(approvalReason: "Pair")
        }) {
            await mac2.messenger.cancelPairing()
        }
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? DeviceMessengerError, .sessionEnded) }
        XCTAssertNil(other.transport.lastSent(.pairingConfirmation, from: mac2.id))
        await XCTAssertEqualAsync(await mac2.phase()?.endReason, .cancelled)
        try await phone2.poll()
        await XCTAssertEqualAsync(await phone2.phase()?.endReason, .cancelledByPeer)
    }

    func testMalformedCodeFailsBeforeAnyNetworkWork() async throws {
        let (harness, mac, _) = try await startedSession()
        // A message still waits in the outbox, which the timers would send first.
        var queued = try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.id))
        queued.recordName = MessageID.random().text
        await mac.messenger.testingQueue(queued)
        let attempts = harness.transport.sentEnvelopes.count
        do {
            try await mac.messenger.enterPairingCode("12a456")
            XCTFail("not six ASCII digits")
        } catch DeviceMessengerError.invalidCodeFormat {}
        XCTAssertEqual(harness.transport.sentEnvelopes.count, attempts, "refused before the queued message is sent")
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else { return XCTFail("not counted") }
    }

    func testCodeEnteredForAReplacedSessionCountsNothingInTheNewOne() async throws {
        let harness = DeviceHarness()
        let transport = SuspendingTransport(harness.transport)
        let mac = DeviceMessenger(identity: SoftwareDeviceIdentity(), platform: .macOS,
                                  registry: PairedDeviceRegistry(store: InMemoryPairedDeviceListStore()),
                                  transport: transport, clock: harness.clock)
        let phone = harness.makeDevice(.iOS)
        let first = try await mac.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: first.text, displayName: "Pocket Phone")
        _ = try await mac.poll()
        try await phone.poll()
        _ = try await mac.poll()
        let firstCode = try await XCTUnwrapAsync(await phone.code())
        // A message still waits in the outbox; the person enters the code, the timers send that
        // message first, and the send stalls.
        var queued = try XCTUnwrap(harness.transport.lastSent(.pairingChallenge, from: mac.deviceID))
        queued.recordName = MessageID.random().text
        await mac.testingQueue(queued)
        transport.holdNextSend()
        let typing = Task { try await mac.enterPairingCode(firstCode.digits) }
        for _ in 0..<10_000 where !transport.isHolding { await Task.yield() }
        XCTAssertTrue(transport.isHolding)
        // Meanwhile the person starts over and a phone joins the new session.
        let second = try await mac.startPairing(displayName: "Studio Mac")
        let tablet = harness.makeDevice(.iOS)
        try await tablet.messenger.joinPairing(scannedText: second.text, displayName: "Tablet")
        _ = try await mac.poll()
        try await tablet.poll()
        _ = try await mac.poll()
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.pairingPhase else {
            return XCTFail("the new session asks for its own code")
        }
        transport.release()
        do {
            try await typing.value
            XCTFail("the code was entered for the replaced session")
        } catch DeviceMessengerError.sessionEnded {}
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.pairingPhase else {
            return XCTFail("the replaced session's code counts nothing in the new one")
        }
        let secondCode = try await XCTUnwrapAsync(await tablet.code())
        try await mac.enterPairingCode(secondCode.digits)
        try await mac.confirmPairing(approvalReason: "Pair")
        guard case .waitingForPeer = await mac.pairingPhase else { return XCTFail("the new session still confirms") }
    }

    func testConfirmationsWhileAnApprovalPromptIsOpenAreRefusedWithoutCounting() async throws {
        let (_, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.enterPairingCode(code.digits)
        let macResult = await whileApprovalPromptIsOpen(on: mac, confirming: {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
        }) {
            do {
                try await mac.messenger.confirmPairing(approvalReason: "Pair")
                XCTFail("the first prompt is still open")
            } catch DeviceMessengerError.confirmationInProgress {}
            do {
                try await mac.messenger.enterPairingCode(Self.wrong(code))
                XCTFail("the session already accepted a code")
            } catch DeviceMessengerError.codeAlreadyAccepted {}
        }
        try macResult.get()
        let phoneResult = await whileApprovalPromptIsOpen(on: phone, confirming: {
            try await phone.messenger.confirmPairing(approvalReason: "Pair")
        }) {
            do {
                try await phone.messenger.confirmPairing(approvalReason: "Pair")
                XCTFail("the first prompt is still open")
            } catch DeviceMessengerError.confirmationInProgress {}
        }
        try phoneResult.get()
        XCTAssertEqual(mac.identity.approvalReasons.count, 1, "one prompt for one confirmation")
        XCTAssertEqual(phone.identity.approvalReasons.count, 1, "one prompt for one confirmation")
        try await mac.poll()
        try await phone.poll()
        try await assertPaired(mac, phone)
    }

    // MARK: Helpers

    /// A Mac asking for the code and a phone showing it: request,
    /// challenge, reveal.
    private func startedSession() async throws -> (DeviceHarness, SimulatedDevice, SimulatedDevice) {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        try await mac.poll()
        return (harness, mac, phone)
    }

    /// Starts `confirming`, holds its first approval prompt open (by
    /// suspending, not blocking a thread) while `body` runs, and always
    /// releases it. Returns how `confirming` ended. Later prompts pass, so a
    /// second prompt fails a test instead of hanging it.
    private func whileApprovalPromptIsOpen(on device: SimulatedDevice,
                                           confirming: @escaping () async throws -> Void,
                                           _ body: () async throws -> Void) async -> Result<Void, Error> {
        let gate = PromptGate()
        device.identity.duringApprovalPrompt = { await gate.holdFirst() }
        defer { device.identity.duringApprovalPrompt = nil }
        let before = device.identity.approvalReasons.count
        let first = Task { try await confirming() }
        for _ in 0..<10_000 where !gate.isHolding { await Task.yield() }
        XCTAssertEqual(device.identity.approvalReasons.count, before + 1, "the first prompt is open")
        do {
            try await body()
        } catch {
            XCTFail("threw \(error) while the prompt was open")
        }
        gate.release()
        return await first.result
    }

    private func assertPaired(_ mac: SimulatedDevice, _ phone: SimulatedDevice,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let macPairing = try await XCTUnwrapAsync(await mac.pairingID(), "the Mac paired", file: file, line: line)
        await XCTAssertEqualAsync(await phone.pairingID(), macPairing, file: file, line: line)
        await XCTAssertEqualAsync(try await mac.entry(for: phone)?.pairingID, macPairing, file: file, line: line)
        await XCTAssertEqualAsync(try await phone.entry(for: mac)?.pairingID, macPairing, file: file, line: line)
    }

    private static func wrong(_ code: PairingCode) -> String {
        PairingCode(value: (code.value + 1) % 1_000_000).digits
    }

    private static func caseName(_ phase: PairingPhase) -> String {
        String(String(describing: phase).prefix { $0 != "(" })
    }

    /// Whether `value` carries the code in any form: the type, its digits,
    /// its formatted text or its number.
    private static func contains(_ code: PairingCode, in value: Any) -> Bool {
        if value is PairingCode { return true }
        if let text = value as? String, text.contains(code.digits) || text.contains(code.formatted) { return true }
        if let number = value as? UInt32, number == code.value { return true }
        if let number = value as? Int, number == Int(code.value) { return true }
        return Mirror(reflecting: value).children.contains { contains(code, in: $0.value) }
    }
}

/// Holds the first approval prompt that reaches it until released; later
/// prompts, and any after the release, pass at once.
private final class PromptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?

    var isHolding: Bool { lock.withLock { held != nil } }

    func holdFirst() async {
        let mustHold = lock.withLock { () -> Bool in
            defer { claimed = true }
            return !claimed && !released
        }
        guard mustHold else { return }
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock { () -> Bool in
                if released { return true }
                held = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }
}

/// Forwards to the in-memory transport; the next send can be held until released.
private final class SuspendingTransport: DeviceTransport, @unchecked Sendable {
    private let inner: InMemoryDeviceTransport
    private let lock = NSLock()
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?

    init(_ inner: InMemoryDeviceTransport) { self.inner = inner }

    var isHolding: Bool { lock.withLock { held != nil } }

    func holdNextSend() { lock.withLock { holdsNext = true } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func send(_ envelope: DeviceEnvelope) async throws {
        let mustHold = lock.withLock { () -> Bool in
            defer { holdsNext = false }
            return holdsNext
        }
        if mustHold {
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
        try await inner.send(envelope)
    }

    func fetchInboxChanges(of device: DeviceID, since token: InboxChangeToken?) async throws -> InboxChanges {
        try await inner.fetchInboxChanges(of: device, since: token)
    }

    func deleteMessages(_ recordNames: [String], from device: DeviceID) async throws {
        try await inner.deleteMessages(recordNames, from: device)
    }
}
