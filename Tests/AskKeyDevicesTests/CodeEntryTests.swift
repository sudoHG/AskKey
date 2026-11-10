@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// #282, decision 5: the iPhone shows the code, the person types it on the
/// Mac, and only a matching code lets the Mac's approval key sign.
final class CodeEntryTests: XCTestCase {
    func testTheRightCodeTypedOnceConfirmsWithOneApprovalPrompt() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
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
                    try await mac.messenger.confirmPairing(enteredCode: Self.wrong(code), approvalReason: "Pair")
                    XCTFail("a wrong code is refused")
                } catch DeviceMessengerError.wrongCode(let remaining) {
                    XCTAssertEqual(remaining, 3 - attempt)
                }
                guard case .enteringCode(_, let left) = await mac.phase() else { return XCTFail("still entering") }
                XCTAssertEqual(left, 3 - attempt)
            }
            XCTAssertTrue(mac.identity.approvalReasons.isEmpty, "a wrong code never reaches the approval key")
            XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))
            XCTAssertNil(harness.transport.lastSent(.pairingCancellation, from: mac.id))
            try await mac.messenger.confirmPairing(enteredCode: code.formatted, approvalReason: "Pair")
            try await phone.messenger.confirmPairing(approvalReason: "Pair")
            try await mac.poll()
            try await phone.poll()
            try await assertPaired(mac, phone)
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
                try await mac.messenger.confirmPairing(enteredCode: Self.wrong(code), approvalReason: "Pair")
            } catch DeviceMessengerError.wrongCode(let left) {
                remaining.append(left)
            }
        }
        XCTAssertEqual(remaining, [2, 1, 0])
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .codeMismatch)
        XCTAssertNotNil(harness.transport.lastSent(.pairingCancellation, from: mac.id), "a signed cancellation")
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        do {
            try await mac.messenger.confirmPairing(enteredCode: code.formatted, approvalReason: "Pair")
            XCTFail("the ended session takes no more codes")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        try await phone.poll()
        await XCTAssertEqualAsync(await phone.phase()?.endReason, .cancelledByPeer)
        await XCTAssertNilAsync(try await mac.entry(for: phone))
        await XCTAssertNilAsync(try await phone.entry(for: mac))
    }

    func testMalformedCodesAreRefusedWithoutCountingAnAttempt() async throws {
        let (_, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        do {
            try await mac.messenger.confirmPairing(enteredCode: Self.wrong(code), approvalReason: "Pair")
            XCTFail("a wrong code is refused")
        } catch DeviceMessengerError.wrongCode(attemptsRemaining: 2) {}
        let malformed = ["", "12345", "1234567", "12a456", "12-345", "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}",
                         "\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}", "123\n456", String(code.digits.dropLast()) + "\u{2460}"]
        for text in malformed {
            do {
                try await mac.messenger.confirmPairing(enteredCode: text, approvalReason: "Pair")
                XCTFail("\(text.debugDescription) is not six ASCII digits")
            } catch DeviceMessengerError.invalidCodeFormat {}
        }
        guard case .enteringCode(_, attemptsRemaining: 2) = await mac.phase() else {
            return XCTFail("malformed input does not count")
        }
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the right code still confirms") }
    }

    func testSpacesInTheTypedCodeAreIgnored() async throws {
        let digits = "012345"
        for text in ["012 345", " 012345 ", "0 1 2 3 4 5", "012\t345", "012\u{00A0}345"] {
            let entered = try XCTUnwrap(EnteredPairingCode(text), text.debugDescription)
            XCTAssertTrue(ComparisonCode(value: 12345).matches(entered), text.debugDescription)
        }
        XCTAssertFalse(ComparisonCode(value: 12346).matches(try XCTUnwrap(EnteredPairingCode(digits))))
        XCTAssertFalse(ComparisonCode(value: 12345).matches(try XCTUnwrap(EnteredPairingCode("12345 0"))))

        let (_, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        try await mac.messenger.confirmPairing(enteredCode: "  \(code.formatted) ", approvalReason: "Pair")
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the code as the phone shows it is accepted") }
    }

    func testTheMacNeverExposesTheCode() async throws {
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
        let code = try await XCTUnwrapAsync(await phone.code())
        do {
            try await mac.messenger.confirmPairing(enteredCode: Self.wrong(code), approvalReason: "Pair")
            XCTFail("a wrong code is refused")
        } catch DeviceMessengerError.wrongCode(attemptsRemaining: 2) {}
        macPhases.append(await mac.phase())
        try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
        macPhases.append(await mac.phase())
        try await phone.messenger.confirmPairing(approvalReason: "Pair")
        try await mac.poll()
        try await phone.poll()
        macPhases.append(await mac.phase())

        XCTAssertEqual(macPhases.compactMap { $0.map(Self.caseName) },
                       ["showingQRCode", "enteringCode", "enteringCode", "waitingForPeer", "paired"])
        for phase in macPhases {
            XCTAssertFalse(Self.containsCode(phase as Any), "\(String(describing: phase)) carries no code")
        }
        let phonePhase = await phone.phase()
        guard case .paired = phonePhase else { return XCTFail("the phone paired") }
        XCTAssertFalse(Self.containsCode(phonePhase as Any), "the paired phone no longer shows it")
    }

    func testThePhoneConfirmsWithoutACodeAndEachSideKeepsItsOwnCall() async throws {
        let (harness, mac, phone) = try await startedSession()
        do {
            try await mac.messenger.confirmPairing(approvalReason: "Pair")
            XCTFail("the Mac cannot confirm without the code")
        } catch DeviceMessengerError.wrongRole {}
        let code = try await XCTUnwrapAsync(await phone.code())
        do {
            try await phone.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
            XCTFail("the phone has no code to type")
        } catch DeviceMessengerError.wrongRole {}
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
        XCTAssertTrue(phone.identity.approvalReasons.isEmpty)
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))

        try await phone.messenger.confirmPairing(approvalReason: "Pair with Studio Mac")
        XCTAssertEqual(phone.identity.approvalReasons, ["Pair with Studio Mac"], "Face ID once, no code")
        XCTAssertNotNil(harness.transport.lastSent(.pairingConfirmation, from: phone.id))
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else {
            return XCTFail("the Mac is unaffected")
        }
        try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
        try await mac.poll()
        try await phone.poll()
        try await assertPaired(mac, phone)
    }

    func testCancelledApprovalAfterTheRightCodeCountsNothingAndCanBeRetried() async throws {
        let (harness, mac, phone) = try await startedSession()
        let code = try await XCTUnwrapAsync(await phone.code())
        mac.identity.approvalBehavior = .cancel
        do {
            try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
            XCTFail("a cancelled prompt throws")
        } catch DeviceIdentityError.authenticationCancelled {}
        XCTAssertNil(harness.transport.lastSent(.pairingConfirmation, from: mac.id))
        guard case .enteringCode(_, attemptsRemaining: 3) = await mac.phase() else {
            return XCTFail("a cancelled prompt is not a wrong code")
        }
        mac.identity.approvalBehavior = .sign
        try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
        XCTAssertEqual(mac.identity.approvalReasons.count, 2)
        guard case .waitingForPeer = await mac.phase() else { return XCTFail("the retry confirms") }
    }

    func testCodeEntryOutsideASessionWaitingForItIsRefused() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        do {
            try await mac.messenger.confirmPairing(enteredCode: "123456", approvalReason: "Pair")
            XCTFail("no session")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        do {
            try await mac.messenger.confirmPairing(enteredCode: "123456", approvalReason: "Pair")
            XCTFail("no request frozen yet")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        try await mac.poll()
        try await phone.poll()
        let code = try await XCTUnwrapAsync(await phone.code())
        harness.clock.advance(by: 10 * 60)
        do {
            try await mac.messenger.confirmPairing(enteredCode: code.digits, approvalReason: "Pair")
            XCTFail("the session expired")
        } catch DeviceMessengerError.notAwaitingConfirmation {}
        await XCTAssertEqualAsync(await mac.phase()?.endReason, .expired)
        XCTAssertTrue(mac.identity.approvalReasons.isEmpty)
    }

    // MARK: Helpers

    /// A Mac asking for the code and a phone showing it.
    private func startedSession() async throws -> (DeviceHarness, SimulatedDevice, SimulatedDevice) {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "Pocket Phone")
        try await mac.poll()
        try await phone.poll()
        return (harness, mac, phone)
    }

    private func assertPaired(_ mac: SimulatedDevice, _ phone: SimulatedDevice,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let macPairing = try await XCTUnwrapAsync(await mac.pairingID(), "the Mac paired", file: file, line: line)
        await XCTAssertEqualAsync(await phone.pairingID(), macPairing, file: file, line: line)
        await XCTAssertEqualAsync(try await mac.entry(for: phone)?.pairingID, macPairing, file: file, line: line)
        await XCTAssertEqualAsync(try await phone.entry(for: mac)?.pairingID, macPairing, file: file, line: line)
    }

    private static func wrong(_ code: ComparisonCode) -> String {
        ComparisonCode(value: (code.value + 1) % 1_000_000).digits
    }

    private static func caseName(_ phase: PairingPhase) -> String {
        String(String(describing: phase).prefix { $0 != "(" })
    }

    private static func containsCode(_ value: Any) -> Bool {
        if value is ComparisonCode { return true }
        return Mirror(reflecting: value).children.contains { containsCode($0.value) }
    }
}
