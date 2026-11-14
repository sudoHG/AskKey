@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// The kind 10–14 layouts and every malformed case ADR 0014 → Encodings names.
final class ApprovalPayloadTests: XCTestCase {
    private func fields() throws -> ApprovalRequest.Fields {
        ApprovalRequest.Fields(pairingID: ApprovalVectorTests.pairingID, responseID: ApprovalVectorTests.responseID,
                               bindingDigest: try ApprovalVectorTests.bindingA(), deadline: 1_800_000_300,
                               launchTime: 1_799_999_000, offers: 0x03, timedDuration: 0, displayFlags: 0,
                               shortenedFlags: 0,
                               texts: ["Codex", "", "GitHub Token", "./deploy.sh --prod", "~/src/app", "deploy.sh"],
                               rows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "GITHUB_TOKEN")])
    }

    private func assertMalformed(_ payload: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ApprovalRequest(decoding: payload), name, file: file, line: line) {
            XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed, name, file: file, line: line)
        }
    }

    private func assertMalformed(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                                 _ change: (inout ApprovalRequest.Fields) -> Void) throws {
        var value = try fields()
        change(&value)
        assertMalformed(value.encoded, name, file: file, line: line)
    }

    func testValidRequestVariantsDecode() throws {
        var value = try fields()
        XCTAssertNoThrow(try ApprovalRequest(decoding: value.encoded))
        value.offers = 0x07
        value.timedDuration = 7_200
        XCTAssertEqual(try ApprovalRequest(decoding: value.encoded).timedDuration, 7_200)
        value.timedDuration = 1
        XCTAssertNoThrow(try ApprovalRequest(decoding: value.encoded))
        value.offers = 0x01
        value.timedDuration = 0
        value.shortenedFlags = 0x7F
        XCTAssertEqual(try ApprovalRequest(decoding: value.encoded).shortened.rawValue, 0x7F, "Deny only allows shortening")
        value.displayFlags = 0x01
        value.rows = []
        XCTAssertTrue(try ApprovalRequest(decoding: value.encoded).deliveryMetadataUnavailable)
        value = try fields()
        value.texts[0] = ""
        value.texts[4] = ""
        value.rows = [ApprovalDeliveryRow(kind: .temporaryFile, label: "key", variable: "KEY_FILE")]
        XCTAssertEqual(try ApprovalRequest(decoding: value.encoded).deliveryRows.first?.kind, .temporaryFile)
        value.rows = []
        XCTAssertNoThrow(try ApprovalRequest(decoding: value.encoded))
    }

    func testRequestWithReservedValuesIsMalformed() throws {
        var bytes = try fields().encoded
        bytes[16] = 2
        assertMalformed(bytes, "layout version 2")
        bytes[16] = 0
        assertMalformed(bytes, "layout version 0")
        for offers: UInt8 in [0x00, 0x02, 0x04, 0x05, 0x06, 0x0F, 0xFF] {
            try assertMalformed("offers \(offers)") { $0.offers = offers; $0.timedDuration = offers & 0x04 != 0 ? 60 : 0 }
        }
        try assertMalformed("timed offered without a duration") { $0.offers = 0x07; $0.timedDuration = 0 }
        try assertMalformed("timed duration over the Broker's maximum") { $0.offers = 0x07; $0.timedDuration = 7_201 }
        try assertMalformed("timed duration without the timed offer") { $0.timedDuration = 1 }
        try assertMalformed("timed duration with Deny only") { $0.offers = 0x01; $0.timedDuration = 5 }
        for flags: UInt8 in [0x02, 0x80, 0xFF] {
            try assertMalformed("display flags \(flags)") { $0.offers = 0x01; $0.displayFlags = flags; $0.rows = [] }
        }
        try assertMalformed("shortened bit 7") { $0.offers = 0x01; $0.shortenedFlags = 0x80 }
        try assertMalformed("shortened without Deny only") { $0.shortenedFlags = 0x01 }
        try assertMalformed("shortened rows without Deny only") { $0.offers = 0x07; $0.timedDuration = 60; $0.shortenedFlags = 0x40 }
        try assertMalformed("unavailable metadata without Deny only") { $0.displayFlags = 0x01; $0.rows = [] }
        try assertMalformed("rows despite unavailable metadata") { $0.offers = 0x01; $0.displayFlags = 0x01 }
        var lateDeadline = try fields().encoded
        lateDeadline.replaceSubrange(65..<73, with: Data(repeating: 0xFF, count: 8))
        assertMalformed(lateDeadline, "a deadline after the year 9999")
    }

    func testRequestTextFieldsAreCappedValidAndFreeOfControlCharacters() throws {
        let caps = [256, 1_024, 1_024, 6_144, 1_024, 256]
        for (index, cap) in caps.enumerated() {
            try assertMalformed("field \(11 + index) over its cap") { $0.texts[index] = String(repeating: "x", count: cap + 1) }
            var atCap = try fields()
            atCap.texts[index] = String(repeating: "x", count: cap)
            XCTAssertNoThrow(try ApprovalRequest(decoding: atCap.encoded), "field \(11 + index) at its cap")
            for scalar in ["\u{0007}", "\n", "\r", "\t", "\u{0085}", "\u{2028}", "\u{2029}", "\u{200E}", "\u{FEFF}",
                           "\u{202E}", "\u{007F}"] {
                try assertMalformed("field \(11 + index) with U+\(String(scalar.unicodeScalars.first!.value, radix: 16))") {
                    $0.texts[index] = "a" + scalar + "b"
                }
            }
        }
        for index in [2, 3, 5] {
            try assertMalformed("empty required field \(11 + index)") { $0.texts[index] = "" }
        }
        let requester = 96..<101 // "Codex" after the 92 fixed bytes and its length.
        for invalid in [Data([0x43, 0xFF, 0x64, 0x65, 0x78]), Data([0xC0, 0x80, 0x64, 0x65, 0x78]),
                        Data([0xED, 0xA0, 0x80, 0x65, 0x78]), Data([0x43, 0x6F, 0x64, 0x65, 0xE2])] {
            var bytes = try fields().encoded
            bytes.replaceSubrange(requester, with: invalid)
            assertMalformed(bytes, "invalid UTF-8 \(invalid.hex)")
        }
        try assertMalformed("a row label with a line break") { $0.rows[0].label = "a\u{2028}b" }
        try assertMalformed("a row variable with a control character") { $0.rows[0].variable = "A\u{0000}" }
    }

    func testRequestRowsFollowTheirRules() throws {
        let row = ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "V")
        try assertMalformed("65 rows") { $0.rows = Array(repeating: row, count: 65) }
        var sixtyFour = try fields()
        sixtyFour.rows = Array(repeating: row, count: 64)
        XCTAssertEqual(try ApprovalRequest(decoding: sixtyFour.encoded).deliveryRows.count, 64)
        try assertMalformed("an empty variable") { $0.rows[0].variable = "" }
        try assertMalformed("a label over 256 bytes") { $0.rows[0].label = String(repeating: "L", count: 257) }
        try assertMalformed("a variable over 256 bytes") { $0.rows[0].variable = String(repeating: "V", count: 257) }
        let wide = ApprovalDeliveryRow(kind: .environmentVariable, label: String(repeating: "L", count: 256), variable: "V")
        try assertMalformed("rows over 3,072 bytes") { $0.rows = Array(repeating: wide, count: 12) + [row] }
        var exact = try fields()
        exact.rows = Array(repeating: wide, count: 11) + [ApprovalDeliveryRow(kind: .temporaryFile, label: "",
                                                                              variable: String(repeating: "V", count: 137))]
        XCTAssertEqual(exact.rows.reduce(0) { $0 + $1.encodedByteCount }, 3_072)
        XCTAssertNoThrow(try ApprovalRequest(decoding: exact.encoded), "exactly 3,072 row bytes")
        for kind: UInt8 in [0, 3, 0xFF] {
            var bytes = try fields().encoded
            let rowStart = bytes.count - (1 + 4 + 4 + 12)
            bytes[rowStart] = kind
            assertMalformed(bytes, "row kind \(kind)")
        }
        var shortCount = try fields().encoded
        shortCount[shortCount.count - 22] = 2
        assertMalformed(shortCount, "a row count above the rows present")
        let trailing = try fields().encoded + [0]
        assertMalformed(trailing, "trailing bytes")
        assertMalformed(try fields().encoded.dropLast(), "truncated")
        assertMalformed(Data(), "empty")
    }

    func testRequestTimesAgainstItsInnerMessage() throws {
        let request = try ApprovalVectorTests.vectorRequest()
        let deadline: Int64 = 1_800_000_300
        XCTAssertNil(request.checkTimes(sentAt: deadline - 300, expiresAt: deadline + 300))
        XCTAssertNil(request.checkTimes(sentAt: deadline - 1, expiresAt: deadline + 1))
        XCTAssertEqual(request.checkTimes(sentAt: deadline, expiresAt: deadline + 1), .malformed, "the deadline has passed")
        XCTAssertEqual(request.checkTimes(sentAt: deadline - 301, expiresAt: deadline + 1), .malformed, "over 300 seconds")
        XCTAssertEqual(request.checkTimes(sentAt: deadline - 300, expiresAt: deadline + 301), .lifetimeTooLong)
        XCTAssertEqual(ApprovalRequest.expiry(sentAt: deadline - 300, deadline: deadline), deadline + 300)
        XCTAssertEqual(ApprovalRequest.expiry(sentAt: deadline - 30, deadline: deadline), deadline + 300)
        XCTAssertEqual(ApprovalRequest.expiry(sentAt: deadline - 300, deadline: deadline - 200), deadline + 100)
    }

    // MARK: Building on the Mac

    func testEscapingAndShortening() {
        XCTAssertEqual(ApprovalText.escaped("a\nb"), "a\\x0ab")
        XCTAssertEqual(ApprovalText.escaped("a\u{2028}b\u{200E}"), "a\\xe2\\x80\\xa8b\\xe2\\x80\\x8e")
        XCTAssertEqual(ApprovalText.escaped("\u{0085}\u{FEFF}"), "\\xc2\\x85\\xef\\xbb\\xbf")
        XCTAssertEqual(ApprovalText.escaped("back\\slash \"quoted\" 😀"), "back\\slash \"quoted\" 😀")
        XCTAssertEqual(ApprovalText.escaped(ApprovalText.escaped("x\ty")), "x\\x09y", "escaping escaped text changes nothing")

        let ascii = String(repeating: "a", count: 150) + String(repeating: "z", count: 150)
        let shortened = ApprovalText.shortened(ascii, cap: 256)
        XCTAssertTrue(shortened.shortened)
        XCTAssertEqual(shortened.text, String(repeating: "a", count: 127) + "…" + String(repeating: "z", count: 126))
        XCTAssertEqual(shortened.text.utf8.count, 256)
        XCTAssertEqual(ApprovalText.shortened(String(repeating: "é", count: 7), cap: 10).text, "éé…é")
        XCTAssertEqual(ApprovalText.shortened("😀😀😀😀", cap: 10).text, "😀…")
        XCTAssertEqual(ApprovalText.shortened("ab😀cd😀ef", cap: 11).text, "ab…😀ef", "whole scalars only")
        XCTAssertFalse(ApprovalText.shortened(String(repeating: "x", count: 256), cap: 256).shortened)
        let long = ApprovalText.shortened(String(repeating: "x", count: 7_000), cap: 6_144).text
        XCTAssertEqual(long.utf8.count, 6_144)
        XCTAssertEqual(Array(long.utf8)[3_071..<3_074], [0xE2, 0x80, 0xA6], "the prefix takes ⌈(cap − 3) / 2⌉ bytes")
    }

    private func build(_ display: ApprovalRequestDisplay, offers: ApprovalOffers = .all,
                       timed: UInt64 = 1_800) throws -> ApprovalRequest {
        try ApprovalVectorTests.vectorRequest(display: display, offers: offers, timed: timed)
    }

    func testBuilderEscapesFieldsAndKeepsOffersWhenNothingIsShortened() throws {
        var display = ApprovalVectorTests.vectorDisplay
        display.requesterName = "Co\u{2028}dex"
        display.purpose = "line one\nline two"
        display.credentialName = "Token\u{200F}"
        let request = try build(display)
        XCTAssertEqual(request.requesterName, "Co\\xe2\\x80\\xa8dex")
        XCTAssertEqual(request.purpose, "line one\\x0aline two")
        XCTAssertEqual(request.credentialName, "Token\\xe2\\x80\\x8f")
        XCTAssertEqual(request.shortened, [])
        XCTAssertEqual(request.offers, .all)
        XCTAssertEqual(request.timedDuration, 1_800)

        display.requesterName = String(repeating: "a", count: 250) + "\n\n"
        let escapedOver = try build(display)
        XCTAssertEqual(escapedOver.shortened, .requesterName, "escaping can push a field over its cap")
        XCTAssertEqual(escapedOver.requesterName.utf8.count, 256)
        XCTAssertEqual(escapedOver.offers, .denyOnly)
    }

    func testBuilderDropsRowsAndOffersDenyOnlyWhenMetadataIsMissingOrRowsDoNotFit() throws {
        var display = ApprovalVectorTests.vectorDisplay
        display.deliveryMetadataUnavailable = true
        let unavailable = try build(display)
        XCTAssertTrue(unavailable.deliveryMetadataUnavailable)
        XCTAssertEqual(unavailable.deliveryRows, [])
        XCTAssertEqual(unavailable.shortened, [])
        XCTAssertEqual(unavailable.offers, .denyOnly)
        XCTAssertEqual(unavailable.timedDuration, 0)

        display = ApprovalVectorTests.vectorDisplay
        display.deliveryRows = Array(repeating: ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "V"),
                                     count: 65)
        let tooMany = try build(display)
        XCTAssertEqual(tooMany.deliveryRows.count, 64)
        XCTAssertEqual(tooMany.shortened, .deliveryRows)
        XCTAssertEqual(tooMany.offers, .denyOnly)

        display.deliveryRows = [ApprovalDeliveryRow(kind: .temporaryFile, label: String(repeating: "L", count: 300),
                                                    variable: "KEY_FILE")]
        let longLabel = try build(display)
        XCTAssertEqual(longLabel.deliveryRows.first?.label.utf8.count, 256)
        XCTAssertEqual(longLabel.shortened, .deliveryRows)
    }

    func testBuilderRefusesWhatCannotBeSent() throws {
        for change in [{ (d: inout ApprovalRequestDisplay) in d.credentialName = "" },
                       { (d: inout ApprovalRequestDisplay) in d.commandLine = "" },
                       { (d: inout ApprovalRequestDisplay) in d.executableName = "" },
                       { (d: inout ApprovalRequestDisplay) in d.deliveryRows[0].variable = "" }] {
            var display = ApprovalVectorTests.vectorDisplay
            change(&display)
            XCTAssertThrowsError(try build(display)) { XCTAssertEqual($0 as? ApprovalMessageError, .invalidDisplay) }
        }
        for (offers, timed) in [(ApprovalOffers.all, UInt64(0)), (.all, 7_201), (.denyOrAllowOnce, 60), (.denyOnly, 1)] {
            XCTAssertThrowsError(try build(ApprovalVectorTests.vectorDisplay, offers: offers, timed: timed)) {
                XCTAssertEqual($0 as? ApprovalMessageError, .invalidTimedDuration)
            }
        }
        XCTAssertThrowsError(try ApprovalRequest.build(display: ApprovalVectorTests.vectorDisplay,
                                                       pairingID: ApprovalVectorTests.pairingID,
                                                       responseID: .random(), bindingDigest: Data(count: 31),
                                                       deadline: 1_800_000_300, launchTime: 0, offers: .denyOnly,
                                                       timedDuration: 0)) {
            XCTAssertEqual($0 as? ApprovalMessageError, .invalidDigest)
        }
    }

    // MARK: Kinds 11–14

    private let header = ApprovalVectorTests.pairingID.rawValue + [1]
    private let digest = ApprovalVectorTests.requestDigest

    private func decision(code: UInt8, ceiling: UInt64, slot: Data) -> Data {
        var writer = ByteWriter()
        writer.append(header)
        writer.append(digest)
        writer.append(code)
        writer.appendUInt64(ceiling)
        writer.append(slot)
        return writer.data
    }

    func testDecisionLayout() throws {
        let signature = Data(repeating: 0xAB, count: 64)
        let zero = Data(count: 64)
        XCTAssertEqual(decision(code: 0, ceiling: 0, slot: zero).count, ApprovalDecision.byteCount)
        let deny = try ApprovalDecision(decoding: decision(code: 0, ceiling: 0, slot: zero))
        XCTAssertEqual(deny.code, .deny)
        XCTAssertNil(deny.approvalSignature)
        XCTAssertEqual(try ApprovalDecision(decoding: decision(code: 1, ceiling: 0, slot: signature)).approvalSignature, signature)
        let timed = try ApprovalDecision(decoding: decision(code: 2, ceiling: 1_800, slot: signature))
        XCTAssertEqual(timed.durationCeiling, 1_800)
        XCTAssertEqual(timed.requestDigest, digest)
        XCTAssertEqual(timed.pairingID, ApprovalVectorTests.pairingID)

        var malformed: [(String, Data)] = [
            ("reserved code 3", decision(code: 3, ceiling: 0, slot: signature)),
            ("reserved code 255", decision(code: 255, ceiling: 0, slot: signature)),
            ("Deny with a ceiling", decision(code: 0, ceiling: 1, slot: zero)),
            ("Allow Once with a ceiling", decision(code: 1, ceiling: 60, slot: signature)),
            ("timed without a ceiling", decision(code: 2, ceiling: 0, slot: signature)),
            ("short", decision(code: 1, ceiling: 0, slot: signature).dropLast()),
            ("long", decision(code: 1, ceiling: 0, slot: signature) + [0]),
        ]
        for index in [0, 31, 63] {
            var slot = zero
            slot[index] = 1
            malformed.append(("Deny with slot byte \(index) set", decision(code: 0, ceiling: 0, slot: slot)))
        }
        var version = decision(code: 0, ceiling: 0, slot: zero)
        version[16] = 2
        malformed.append(("layout version 2", version))
        for (name, payload) in malformed {
            XCTAssertThrowsError(try ApprovalDecision(decoding: payload), name) {
                XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed, name)
            }
        }
    }

    private func closed(_ outcome: UInt8, code: UInt8 = 0, duration: UInt64 = 0) -> Data {
        var writer = ByteWriter()
        writer.append(header)
        writer.append(digest)
        writer.append(outcome)
        writer.append(code)
        writer.appendUInt64(duration)
        return writer.data
    }

    func testClosedLayout() throws {
        XCTAssertEqual(closed(1).count, ApprovalClosed.byteCount)
        XCTAssertEqual(try ApprovalClosed(decoding: closed(1, code: 2, duration: 900)).appliedDuration, 900)
        XCTAssertEqual(try ApprovalClosed(decoding: closed(1, code: 2, duration: 7_200)).appliedDuration, 7_200)
        XCTAssertEqual(try ApprovalClosed(decoding: closed(1, code: 2, duration: 0)).appliedDuration, 0, "rounded down to nothing")
        XCTAssertEqual(try ApprovalClosed(decoding: closed(1, code: 0)).appliedCode, .deny)
        XCTAssertEqual(try ApprovalClosed(decoding: closed(1, code: 1)).appliedCode, .allowOnce)
        for outcome: UInt8 in 2...6 {
            let decoded = try ApprovalClosed(decoding: closed(outcome))
            XCTAssertEqual(decoded.outcome.rawValue, outcome)
            XCTAssertNil(decoded.appliedCode)
        }
        var malformed: [(String, Data)] = [
            ("outcome 0", closed(0)), ("outcome 7", closed(7)), ("outcome 1 with code 3", closed(1, code: 3)),
            ("outcome 1, Deny with a duration", closed(1, code: 0, duration: 1)),
            ("outcome 1, Allow Once with a duration", closed(1, code: 1, duration: 1)),
            ("outcome 1, timed over the Broker's maximum", closed(1, code: 2, duration: 7_201)),
            ("outcome 1, timed with the largest duration", closed(1, code: 2, duration: .max)),
            ("short", closed(2).dropLast()), ("long", closed(2) + [0]),
        ]
        for outcome: UInt8 in 2...6 {
            malformed.append(("outcome \(outcome) with a code", closed(outcome, code: 1)))
            malformed.append(("outcome \(outcome) with a duration", closed(outcome, duration: 1)))
        }
        var version = closed(2)
        version[16] = 0
        malformed.append(("layout version 0", version))
        for (name, payload) in malformed {
            XCTAssertThrowsError(try ApprovalClosed(decoding: payload), name) {
                XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed, name)
            }
        }
    }

    func testReceiptAndConfirmationLayouts() throws {
        let receipt = header + digest
        XCTAssertEqual(receipt.count, ApprovalReceipt.byteCount)
        XCTAssertEqual(try ApprovalReceipt(decoding: receipt).requestDigest, digest)
        let confirmation = header + Data(repeating: 0xCD, count: 32) + Data(repeating: 0xEF, count: 64)
        XCTAssertEqual(confirmation.count, ApproverConfirmation.byteCount)
        XCTAssertEqual(try ApproverConfirmation(decoding: confirmation).codeProof, Data(repeating: 0xCD, count: 32))
        var receiptVersion = receipt
        receiptVersion[16] = 2
        var confirmationVersion = confirmation
        confirmationVersion[16] = 2
        let malformedReceipts = [receipt.dropLast(), receipt + [0], receiptVersion]
        let malformedConfirmations = [confirmation.dropLast(), confirmation + [0], confirmationVersion]
        for payload in malformedReceipts {
            XCTAssertThrowsError(try ApprovalReceipt(decoding: Data(payload))) {
                XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed)
            }
        }
        for payload in malformedConfirmations {
            XCTAssertThrowsError(try ApproverConfirmation(decoding: Data(payload))) {
                XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed)
            }
        }
    }
}
