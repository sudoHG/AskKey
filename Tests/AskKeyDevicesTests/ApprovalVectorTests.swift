@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Fixed vectors of ADR 0014 → Encodings, with the inputs the ADR lists;
/// the expected outputs come from an independent Python implementation
/// (hashlib, hmac) recorded in the pull request.
final class ApprovalVectorTests: XCTestCase {
    static let approver = DeviceID(rawValue: Data(0x10...0x1F))!
    static let requester = DeviceID(rawValue: Data(0x20...0x2F))!
    static let pairingID = PairingID(rawValue: Data(0x30...0x3F))!
    static let responseID = MessageID(rawValue: Data(0x40...0x4F))!
    static let requestDigest = Data(0x50...0x6F)

    static func bindingA(retransmission: String? = nil) throws -> Data {
        try ApprovalBinding.digest(requestID: "6F1C2A9E-4B3D-4E5F-8A7B-9C0D1E2F3A4B", operationID: "op-0001",
                                   credentialID: "7A8B9C0D-1E2F-4A3B-8C4D-5E6F7A8B9C0D",
                                   targetID: "7A8B9C0D-1E2F-4A3B-8C4D-5E6F7A8B9C0D", operation: "read",
                                   payloadDigest: String(repeating: "a", count: 64),
                                   readProjectionDigest: String(repeating: "b", count: 64),
                                   retransmissionDigest: retransmission)
    }

    func testBindingDigests() throws {
        XCTAssertEqual(try Self.bindingA().hex, "a5203d99ab8139de5cefac9aa2e442f2eeff1ef730cf7a4689a4ed2a9d217a5e")
        XCTAssertEqual(try Self.bindingA(retransmission: "").hex, try Self.bindingA().hex, "absent is the empty string")
        XCTAssertEqual(try Self.bindingA(retransmission: String(repeating: "C", count: 64)).hex,
                       "28015f23edcfac3663bf6bb09301ca84c0a3a33c9bbc3233788016dc7eda85ab", "no case folding")
        XCTAssertThrowsError(try ApprovalBinding.digest(requestID: String(repeating: "r", count: 4_097), operationID: "",
                                                        credentialID: "", targetID: "", operation: "read",
                                                        payloadDigest: nil, readProjectionDigest: nil,
                                                        retransmissionDigest: nil)) {
            XCTAssertEqual($0 as? ApprovalMessageError, .invalidDigest)
        }
        XCTAssertNoThrow(try ApprovalBinding.digest(requestID: String(repeating: "r", count: 4_096), operationID: "",
                                                    credentialID: "", targetID: "", operation: "read", payloadDigest: nil,
                                                    readProjectionDigest: nil, retransmissionDigest: nil))
    }

    func testReceiptID() {
        XCTAssertEqual(ApprovalReceipt.receiptID(for: Self.responseID).rawValue.hex, "3e47419d9ec526575d1e0b43950df617")
    }

    func testDecisionStatements() {
        let timed = ApprovalDecision.statement(approver: Self.approver, requester: Self.requester, pairingID: Self.pairingID,
                                               requestDigest: Self.requestDigest, code: .timedAllowance,
                                               durationCeiling: 1_800)
        XCTAssertEqual(Data(SHA256.hash(data: timed)).hex, "76340bfb4dbe4fc9cec1595340818e19fcc05be332357a40770fd56151de97d6")
        XCTAssertEqual(timed.count, 28 + 16 + 16 + 16 + 32 + 1 + 8)
        let once = ApprovalDecision.statement(approver: Self.approver, requester: Self.requester, pairingID: Self.pairingID,
                                              requestDigest: Self.requestDigest, code: .allowOnce, durationCeiling: 0)
        XCTAssertEqual(Data(SHA256.hash(data: once)).hex, "0d3be7ecd11377e27d282442edde99f766ae0ea0124721beb8c07afa86901c0e")
    }

    func testCodeProofAndConfirmationStatement() throws {
        let code = try XCTUnwrap(ApproverCode(typed: "042917"))
        let proof = code.proof(mac: Self.requester, phone: Self.approver, pairingID: Self.pairingID)
        XCTAssertEqual(proof.hex, "720c17b6e53689724891e64a1740f0e12d7647cfe0f6dcb3397915136a1fb8a4")
        let statement = ApproverConfirmation.statement(phone: Self.approver, mac: Self.requester, pairingID: Self.pairingID,
                                                       codeProof: proof)
        XCTAssertEqual(Data(SHA256.hash(data: statement)).hex,
                       "b2c73c19ef9f9350261cfc26c2a2084b9d4e46d4d8267c6fc8274ec92c65cc73")
        XCTAssertTrue(code.matches(proof: proof, mac: Self.requester, phone: Self.approver, pairingID: Self.pairingID))
        var wrong = proof
        wrong[31] ^= 1
        XCTAssertFalse(code.matches(proof: wrong, mac: Self.requester, phone: Self.approver, pairingID: Self.pairingID))
        XCTAssertFalse(code.matches(proof: proof.prefix(31), mac: Self.requester, phone: Self.approver,
                                    pairingID: Self.pairingID))
        XCTAssertFalse(code.matches(proof: proof, mac: Self.approver, phone: Self.requester, pairingID: Self.pairingID),
                       "the proof names the Mac and the iPhone in order")
    }

    func testApproverCodeEntryAndRedaction() throws {
        let code = try XCTUnwrap(ApproverCode(typed: " 042\t917\n"))
        XCTAssertEqual(code.digits, "042917")
        XCTAssertEqual(code.formatted, "042 917")
        XCTAssertEqual(ApproverCode(typed: "042\u{3000}917")?.digits, "042917", "the full-width space is white space")
        for invalid in ["04291", "0429170", "04291a", "\u{FF10}42917", "", "042-917", "٠٤٢٩١٧"] {
            XCTAssertNil(ApproverCode(typed: invalid), invalid)
        }
        XCTAssertEqual(String(describing: code), "ApproverCode(redacted)")
        XCTAssertFalse(String(reflecting: code).contains("042"))
        XCTAssertFalse("\(code)".contains("917"))
        var dumped = ""
        dump(code, to: &dumped)
        XCTAssertFalse(dumped.contains("42917"))
        let drawn = (0..<200).map { _ in ApproverCode.random().digits }
        XCTAssertTrue(drawn.allSatisfy { $0.count == 6 && $0.allSatisfy(\.isASCII) })
        XCTAssertGreaterThan(Set(drawn).count, 190)
    }

    // MARK: Requests

    static let vectorDisplay = ApprovalRequestDisplay(
        requesterName: "Codex", purpose: "", credentialName: "GitHub Token", commandLine: "./deploy.sh --prod",
        workingDirectory: "~/src/app", executableName: "deploy.sh",
        deliveryRows: [ApprovalDeliveryRow(kind: .environmentVariable, label: "", variable: "GITHUB_TOKEN")])

    static func vectorRequest(display: ApprovalRequestDisplay = vectorDisplay, offers: ApprovalOffers = .denyOrAllowOnce,
                              timed: UInt64 = 0) throws -> ApprovalRequest {
        try ApprovalRequest.build(display: display, pairingID: pairingID, responseID: responseID,
                                  bindingDigest: try bindingA(), deadline: 1_800_000_300, launchTime: 1_799_999_000,
                                  offers: offers, timedDuration: timed)
    }

    /// The inner message of ADR 0014's request-digest vector: its 64-byte
    /// signature slot holds 0x77 bytes, so it needs no signing.
    static func vectorInner(payload: Data) throws -> InnerMessage {
        var writer = ByteWriter()
        writer.append(1)
        writer.append(MessageKind.approvalRequest.rawValue)
        writer.append(requester.rawValue)
        writer.append(approver.rawValue)
        writer.append(Data(0x70...0x7F))
        writer.appendTime(1_800_000_000)
        writer.appendTime(1_800_000_600)
        writer.appendLengthPrefixed(payload)
        writer.append(Data(repeating: 0x77, count: 64))
        return try InnerMessage(parsing: writer.data)
    }

    func testRequestDigestVector() throws {
        let request = try Self.vectorRequest()
        XCTAssertEqual(request.encoded.count, 191)
        XCTAssertEqual(request.shortened, [])
        XCTAssertEqual(request.offers, .denyOrAllowOnce)
        let inner = try Self.vectorInner(payload: request.encoded)
        XCTAssertEqual(inner.bytes.count, 325)
        XCTAssertEqual(inner.digest.hex, "7127a61f029d89f0a3804eee11f5a13090388e21c34e6c51b5e796fc78c73067")
        XCTAssertNil(request.checkTimes(sentAt: inner.sentAt, expiresAt: inner.expiresAt))

        let decoded = try ApprovalRequest(decoding: request.encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.pairingID, Self.pairingID)
        XCTAssertEqual(decoded.responseID, Self.responseID)
        XCTAssertEqual(decoded.bindingDigest, try Self.bindingA())
        XCTAssertEqual(decoded.deadline, Date(timeIntervalSince1970: 1_800_000_300))
        XCTAssertEqual(decoded.launchTime, Date(timeIntervalSince1970: 1_799_999_000))
        XCTAssertEqual(decoded.timedDuration, 0)
        XCTAssertFalse(decoded.deliveryMetadataUnavailable)
        XCTAssertEqual([decoded.requesterName, decoded.purpose, decoded.credentialName, decoded.commandLine,
                        decoded.workingDirectory, decoded.executableName],
                       ["Codex", "", "GitHub Token", "./deploy.sh --prod", "~/src/app", "deploy.sh"])
        XCTAssertEqual(decoded.deliveryRows, Self.vectorDisplay.deliveryRows)
        XCTAssertEqual(request.encoded.subdata(in: 92..<96), Data([0, 0, 0, 5]), "the requester's length follows the 92 fixed bytes")
        XCTAssertEqual(request.encoded.subdata(in: 0..<17), Self.pairingID.rawValue + [1])
    }

    static func maximumDisplay(extra field: Int? = nil, longerFirstLabel: Bool = false) -> ApprovalRequestDisplay {
        let caps = [256, 1_024, 1_024, 6_144, 1_024, 256]
        let texts = caps.enumerated().map { String(repeating: "x", count: $1 + ($0 == field ? 1 : 0)) }
        var rows = Array(repeating: ApprovalDeliveryRow(kind: .environmentVariable, label: String(repeating: "L", count: 19),
                                                        variable: String(repeating: "V", count: 20)), count: 64)
        if longerFirstLabel { rows[0].label += "L" }
        return ApprovalRequestDisplay(requesterName: texts[0], purpose: texts[1], credentialName: texts[2],
                                      commandLine: texts[3], workingDirectory: texts[4], executableName: texts[5],
                                      deliveryRows: rows)
    }

    func testMaximumSizeRequestVectorSealsAndOpens() async throws {
        let request = try Self.vectorRequest(display: Self.maximumDisplay(), offers: .all, timed: 1_800)
        XCTAssertEqual(request.encoded.count, ApprovalRequest.maximumByteCount)
        XCTAssertEqual(request.encoded.count, 12_917)
        XCTAssertEqual(Data(SHA256.hash(data: request.encoded)).hex,
                       "1c9f2352560a38c1720889efa5a0a7ce3de2ccbb2d6d384336ac1b82afbd088c")
        XCTAssertEqual(request.shortened, [])
        XCTAssertEqual(request.offers, .all)
        XCTAssertEqual(request.deliveryRows.reduce(0) { $0 + $1.encodedByteCount }, 3_072)
        XCTAssertLessThan(request.encoded.count, InnerMessage.maximumPayloadByteCount)

        let mac = SoftwareDeviceIdentity()
        let phone = SoftwareDeviceIdentity()
        let sealed = try MessageCodec.seal(kind: .approvalRequest, payload: request.encoded, identity: mac,
                                           recipient: phone.deviceID, recipientKey: phone.agreementPublicKey,
                                           preSharedKey: nil, sentAt: 1_800_000_000, expiresAt: 1_800_000_600)
        let now = Date(timeIntervalSince1970: 1_800_000_001)
        let routing = try MessageCodec.routing(of: sealed.envelope, ownID: phone.deviceID, now: now)
        let inner = try MessageCodec.open(sealed.envelope, routing: routing, ownID: phone.deviceID, identity: phone,
                                          preSharedKey: nil, now: now)
        XCTAssertEqual(try ApprovalRequest(decoding: inner.payload), request)
    }

    func testOneMoreByteShortensTheFieldAndOneMoreRowByteDropsTheLastRow() throws {
        let flags: [ApprovalShortenedFields] = [.requesterName, .purpose, .credentialName, .commandLine, .workingDirectory,
                                                .executableName]
        for (field, flag) in flags.enumerated() {
            let request = try Self.vectorRequest(display: Self.maximumDisplay(extra: field), offers: .all, timed: 1_800)
            XCTAssertEqual(request.shortened, flag, "field \(11 + field)")
            XCTAssertEqual(request.offers, .denyOnly, "a shortened field offers only Deny")
            XCTAssertEqual(request.timedDuration, 0)
            XCTAssertLessThanOrEqual(request.encoded.count, ApprovalRequest.maximumByteCount)
            XCTAssertTrue(try ApprovalRequest(decoding: request.encoded).shortened.contains(flag))
        }
        let dropped = try Self.vectorRequest(display: Self.maximumDisplay(longerFirstLabel: true), offers: .all, timed: 1_800)
        XCTAssertEqual(dropped.deliveryRows.count, 63, "the row that no longer fits is dropped")
        XCTAssertEqual(dropped.deliveryRows.first?.label.count, 20)
        XCTAssertEqual(dropped.shortened, .deliveryRows)
        XCTAssertEqual(dropped.offers, .denyOnly)
    }
}
