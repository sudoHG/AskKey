import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import XCTest

/// Fixed test vectors for ADR 0013 → Pairing, computed by an independent
/// implementation of the same derivations.
final class PairingVectorTests: XCTestCase {
    private static let sessionID = PairingSessionID(rawValue: Data(0xA0...0xAF))!
    private static let secret = Data(0xB0...0xCF)
    private static let qrExpiry = Date(timeIntervalSince1970: 1_800_000_300)
    private static let qrText = "ASKKEY-PAIR1:AaChoqOkpaanqKmqq6ytrq-wsbKztLW2t7i5uru8vb6_wMHCw8TFxsfIycrLzM3OzwAAAABrSdMsAlFcPW6545a5BNP-yn9U_c0MwemXvzddylFa0KbDtANfAx8UAUa_sbJR-E9N2-DUzc_Xev2YSpUg41eUAh-DErue"

    private static func macIdentity() throws -> SoftwareDeviceIdentity {
        SoftwareDeviceIdentity(messageKey: try P256.Signing.PrivateKey(rawRepresentation: Data(1...32)),
                               agreementKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(0x21...0x40)),
                               approvalKey: P256.Signing.PrivateKey())
    }

    private static func payload() throws -> PairingQRPayload {
        let mac = try macIdentity()
        return PairingQRPayload(sessionID: sessionID, secret: secret, qrExpiry: qrExpiry,
                                initiatorMessageKey: mac.messagePublicKey, initiatorAgreementKey: mac.agreementPublicKey)
    }

    func testQRPayloadVector() throws {
        let payload = try Self.payload()
        XCTAssertEqual(payload.bytes.count, 123)
        XCTAssertEqual(payload.text, Self.qrText)
        XCTAssertEqual(payload.text.count, 177)
        XCTAssertEqual(payload.initiatorID.text, "6teudjfnonhww7qypn5m2pcsae")
        let decoded = try PairingQRPayload(text: Self.qrText)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.sessionID, Self.sessionID)
        XCTAssertEqual(decoded.qrExpiry, Self.qrExpiry)
    }

    func testPreSharedKeyVector() {
        let key = PairingDerivation.preSharedKey(secret: Self.secret, sessionID: Self.sessionID)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.hex,
                       "e02532c7ca188dfd1a6281ffc65695d7c4d824eb184a70f25e0898c0114317de")
    }

    func testTranscriptHashComparisonCodeAndPairingIDVectors() throws {
        let hash = PairingDerivation.transcriptHash(qrPayload: try Self.payload().bytes,
                                                    responderCard: Data(repeating: 0x11, count: 173),
                                                    initiatorCard: Data(repeating: 0x22, count: 173),
                                                    nonce: Data(repeating: 0x33, count: 32))
        XCTAssertEqual(hash.hex, "e5ffa6541e0e13c0c40f86b66ac6227e956312d5daf359cabf7a5ed0664d59b0")
        let code = PairingDerivation.comparisonCode(secret: Self.secret, transcriptHash: hash)
        XCTAssertEqual(code.digits, "517087")
        XCTAssertEqual(code.formatted, "517 087")
        XCTAssertEqual(PairingDerivation.pairingID(transcriptHash: hash).rawValue.hex, "43ce7440cc92be28cb3eb62b96b829a4")
    }

    func testQRPayloadHoldsNoNameAndStaysWithinTheStatedSize() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let qr = try await mac.messenger.startPairing(displayName: "Hogan's Studio Mac")
        XCTAssertEqual(qr.text.count, PairingQRPayload.textLength)
        XCTAssertLessThanOrEqual(qr.text.count, PairingQRPayload.maximumTextLength)
        XCTAssertTrue(qr.text.hasPrefix("ASKKEY-PAIR1:"))
        XCTAssertFalse(qr.text.contains("://"), "not a URL")
        XCTAssertNil(qr.bytes.range(of: Data("Studio".utf8)))
        XCTAssertFalse(qr.text.contains("Studio"))
        XCTAssertEqual(qr.qrExpiry.timeIntervalSince(harness.clock.now()), 300)
        XCTAssertEqual(qr.initiatorID, mac.id)
    }

    func testScannedTextIsDecodedStrictly() throws {
        let body = String(Self.qrText.dropFirst(PairingQRPayload.prefix.count))
        let cases: [(String, PairingQRPayloadError)] = [
            ("https://askkey.sudohg.com/pair", .notAPairingCode),
            ("askkey-pair1:" + body, .notAPairingCode),
            ("ASKKEY-PAIR2:" + body, .notAPairingCode),
            (String(Self.qrText.dropLast()), .malformed),
            (Self.qrText + "A", .malformed),
            (PairingQRPayload.prefix + body.replacingOccurrences(of: "-", with: "+"), .malformed),
            (String(Self.qrText.dropLast()) + "=", .malformed),
            ("ASKKEY-PAIR1:Ag" + body.dropFirst(2), .malformed),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try PairingQRPayload(text: text), text) {
                XCTAssertEqual($0 as? PairingQRPayloadError, expected, text)
            }
        }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
