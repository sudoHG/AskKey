@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import XCTest

/// The payload layout of each stage 2 kind, as fixed by #284, with fixed
/// inputs. Fixed-size fields are raw bytes; display names carry a 4-byte
/// big-endian length prefix.
final class PayloadLayoutTests: XCTestCase {
    private let sessionID = PairingSessionID(rawValue: Data(0xA0...0xAF))!
    private let pairingID = PairingID(rawValue: Data(0x10...0x1F))!
    private let checkID = MessageID(rawValue: Data(0x20...0x2F))!

    func testFixedSizePayloadVectors() throws {
        XCTAssertEqual(PairingCancellationPayload(sessionID: sessionID).encoded.hex, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        XCTAssertEqual(PairingIDPayload(pairingID: pairingID).encoded.hex, "101112131415161718191a1b1c1d1e1f")
        XCTAssertEqual(DeliveryCheckReplyPayload(pairingID: pairingID, checkMessageID: checkID).encoded.hex,
                       "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f")
        let signer = DeviceID(rawValue: Data(0x30...0x3F))!
        let transcript = Data(repeating: 0x44, count: 32)
        let signature = Data(repeating: 0x55, count: 64)
        let confirmation = PairingConfirmationPayload.encode(role: .responder, signer: signer, transcriptHash: transcript,
                                                             signature: signature)
        XCTAssertEqual(confirmation.hex, "02" + "303132333435363738393a3b3c3d3e3f" + String(repeating: "44", count: 32)
                       + String(repeating: "55", count: 64))
        XCTAssertEqual(PairingConfirmationPayload.signedBytes(role: .initiator, signer: signer, transcriptHash: transcript).hex,
                       Data("AskKey pairing confirmation v1".utf8).hex + "00" + "01" + "303132333435363738393a3b3c3d3e3f"
                       + String(repeating: "44", count: 32))
        let decoded = try PairingConfirmationPayload(decoding: confirmation)
        XCTAssertEqual(decoded.role, .responder)
        XCTAssertEqual(decoded.signer, signer)
        XCTAssertEqual(decoded.signedFields, confirmation.prefix(49))
        XCTAssertThrowsError(try PairingConfirmationPayload(decoding: confirmation.dropLast()))
        XCTAssertThrowsError(try PairingConfirmationPayload(decoding: Data([3]) + confirmation.dropFirst()))
        XCTAssertThrowsError(try PairingIDPayload(decoding: Data(0x10...0x1F) + [0]))

        let reveal = PairingRevealPayload(sessionID: sessionID, challengeDigest: Data(repeating: 0x66, count: 32),
                                          secret: Data(repeating: 0x77, count: 32)).encoded
        XCTAssertEqual(reveal.hex, "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf" + String(repeating: "66", count: 32)
                       + String(repeating: "77", count: 32))
        let decodedReveal = try PairingRevealPayload(decoding: reveal)
        XCTAssertEqual(decodedReveal.secret, Data(repeating: 0x77, count: 32))
        XCTAssertThrowsError(try PairingRevealPayload(decoding: reveal.dropLast()))
        XCTAssertThrowsError(try PairingRevealPayload(decoding: reveal + [0]))
    }

    func testCardBearingPayloadLayouts() throws {
        let card = try DeviceCard.make(identity: SoftwareDeviceIdentity(), platform: .iOS,
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let commitment = Data(repeating: 0x88, count: 32)
        let request = PairingRequestPayload(sessionID: sessionID, card: card, commitment: commitment,
                                            displayName: "Phone").encoded
        XCTAssertEqual(request, sessionID.rawValue + card.bytes + commitment + Data([0, 0, 0, 5]) + Data("Phone".utf8))
        XCTAssertEqual(try PairingRequestPayload(decoding: request).commitment, commitment)
        let nonce = Data(repeating: 0x66, count: 32)
        let digest = Data(repeating: 0x77, count: 32)
        let challenge = PairingChallengePayload(sessionID: sessionID, requestDigest: digest, card: card, nonce: nonce,
                                                displayName: "").encoded
        XCTAssertEqual(challenge, sessionID.rawValue + digest + card.bytes + nonce + Data([0, 0, 0, 0]))
        XCTAssertEqual(PairingWithdrawalPayload(sessionID: sessionID, card: card).encoded, sessionID.rawValue + card.bytes)

        let decodedChallenge = try PairingChallengePayload(decoding: challenge)
        XCTAssertEqual(decodedChallenge.card, card)
        XCTAssertEqual(decodedChallenge.nonce, nonce)
        XCTAssertEqual(try PairingWithdrawalPayload(decoding: sessionID.rawValue + card.bytes).card, card)
        var damaged = request
        damaged[25] ^= 1 // the low byte of the card's creation time
        XCTAssertThrowsError(try PairingRequestPayload(decoding: damaged)) {
            XCTAssertEqual($0 as? DeviceMessageRefusal, .badSignature)
        }
        XCTAssertThrowsError(try PairingRequestPayload(decoding: request + [0]))
        XCTAssertThrowsError(try PairingRequestPayload(decoding: sessionID.rawValue + card.bytes + commitment
                                                       + Data([0, 0, 0, 2, 0xC3, 0x28]))) {
            XCTAssertEqual($0 as? DeviceMessageRefusal, .malformed, "not UTF-8")
        }
    }
}
