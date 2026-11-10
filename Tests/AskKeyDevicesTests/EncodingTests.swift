@testable import AskKeyDevices
import AskKeyDevicesTestSupport
import CryptoKit
import LocalAuthentication
import XCTest

final class EncodingTests: XCTestCase {
    func testDeviceIDTextIsCanonicalLowercaseBase32() throws {
        let identity = SoftwareDeviceIdentity()
        let id = DeviceID(messagePublicKey: identity.messagePublicKey)
        let digest = SHA256.hash(data: Data("AskKey device id v1".utf8) + [0] + identity.messagePublicKey.compressedRepresentation)
        XCTAssertEqual(id.rawValue, Data(digest.prefix(16)))
        XCTAssertEqual(id.text.count, 26)
        XCTAssertEqual(id.text, id.text.lowercased())
        XCTAssertEqual(DeviceID(text: id.text), id)
        XCTAssertNil(DeviceID(text: id.text.uppercased()))
        XCTAssertNil(DeviceID(text: id.text + "="))
        XCTAssertNil(DeviceID(text: String(id.text.dropLast())))
        XCTAssertNil(DeviceID(text: "1" + id.text.dropFirst()))
        // The last character carries two unused bits, which must be zero.
        let zero = DeviceID(rawValue: Data(count: 16))!
        XCTAssertEqual(zero.text, String(repeating: "a", count: 26))
        XCTAssertNil(DeviceID(text: String(repeating: "a", count: 25) + "b"))
        XCTAssertNotNil(DeviceID(text: String(repeating: "a", count: 25) + "e"))
        XCTAssertNil(DeviceID(rawValue: Data(count: 15)))
    }

    func testDeviceCardHasTheVersionOneLayoutAndIsVerifiedStrictly() throws {
        let identity = SoftwareDeviceIdentity()
        let created = Date(timeIntervalSince1970: 1_800_000_123)
        let card = try DeviceCard.make(identity: identity, platform: .iOS, createdAt: created)
        let bytes = card.bytes
        XCTAssertEqual(bytes.count, 173)
        XCTAssertEqual(bytes[0], 1)
        XCTAssertEqual(bytes[1], 2)
        XCTAssertEqual(bytes.subdata(in: 2..<10), Data([0, 0, 0, 0, 0x6B, 0x49, 0xD2, 0x7B]))
        XCTAssertEqual(bytes.subdata(in: 10..<43), identity.messagePublicKey.compressedRepresentation)
        XCTAssertEqual(bytes.subdata(in: 43..<76), identity.agreementPublicKey.compressedRepresentation)
        XCTAssertEqual(bytes.subdata(in: 76..<109), identity.approvalPublicKey.compressedRepresentation)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: bytes.suffix(64))
        XCTAssertTrue(identity.messagePublicKey.isValidSignature(signature, for: Data("AskKey device card v1".utf8) + [0] + bytes.prefix(109)))
        XCTAssertEqual(card.deviceID, identity.deviceID)
        XCTAssertEqual(card.createdAt, created)
        XCTAssertEqual(try DeviceCard(bytes: bytes), card)

        func refusal(_ change: (inout Data) -> Void) -> DeviceCardError? {
            var copy = bytes
            change(&copy)
            do { _ = try DeviceCard(bytes: copy); return nil } catch { return error as? DeviceCardError }
        }
        XCTAssertEqual(refusal { $0[5] ^= 1 }, .badSignature)
        XCTAssertEqual(refusal { $0[172] ^= 1 }, .badSignature)
        XCTAssertEqual(refusal { $0[0] = 2 }, .malformed)
        XCTAssertEqual(refusal { $0[1] = 3 }, .malformed)
        XCTAssertEqual(refusal { $0[10] = 5 }, .malformed)
        XCTAssertEqual(refusal { $0.removeLast() }, .malformed)
        XCTAssertEqual(refusal { $0.append(0) }, .malformed)
        // A card whose message key is also its approval key.
        let key = P256.Signing.PrivateKey()
        XCTAssertThrowsError(try DeviceCard.make(identity: SoftwareDeviceIdentity(messageKey: key, agreementKey: .init(), approvalKey: key),
                                                 platform: .macOS, createdAt: created))
    }

    func testDisplayNamesAreCleanedAndTrimmed() {
        XCTAssertEqual(DeviceDisplayName.clean("  Studio Mac \n"), "Studio Mac")
        XCTAssertEqual(DeviceDisplayName.clean("Desk\u{0000}\u{0007}\u{001B}\u{007F}\u{0085} Phone"), "Desk Phone")
        let bidi = [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        let withBidi = "A" + bidi.map { String(UnicodeScalar($0)!) }.joined() + "B"
        XCTAssertEqual(DeviceDisplayName.clean(withBidi), "AB")
        XCTAssertEqual(DeviceDisplayName.clean("\u{05D0}\u{05D1} Mac"), "\u{05D0}\u{05D1} Mac", "right-to-left letters stay")
        XCTAssertEqual(DeviceDisplayName.clean(String(repeating: "x", count: 100)).unicodeScalars.count, 64)
        let emoji = String(repeating: "\u{1F600}", count: 70)
        let cleanedEmoji = DeviceDisplayName.clean(emoji)
        XCTAssertEqual(cleanedEmoji.unicodeScalars.count, 64)
        XCTAssertEqual(cleanedEmoji.utf8.count, 256)
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let families = DeviceDisplayName.clean(String(repeating: family, count: 20))
        XCTAssertEqual(families.count, 12, "whole characters only: 12 families are 60 scalars")
        XCTAssertTrue(families.allSatisfy { String($0) == family })
        XCTAssertEqual(DeviceDisplayName.clean(String(repeating: "\u{4E2D}", count: 90)).utf8.count, 192)
        XCTAssertEqual(DeviceDisplayName.clean(String(repeating: "x", count: 63) + " y"), String(repeating: "x", count: 63))
        XCTAssertEqual(DeviceDisplayName.clean("\u{202E}\n"), "")
    }

    func testNamesTravelOnlyInsideSealedPayloadsAndAreCleanedOnReceipt() async throws {
        let harness = DeviceHarness()
        let mac = harness.makeDevice(.macOS)
        let phone = harness.makeDevice(.iOS)
        let qr = try await mac.messenger.startPairing(displayName: "Studio\u{202E} Mac")
        try await phone.messenger.joinPairing(scannedText: qr.text, displayName: "\tPocket\u{200F} Phone  ")
        let request = try XCTUnwrap(harness.transport.lastSent(.pairingRequest, from: phone.id))
        XCTAssertNil(request.body.range(of: Data("Pocket".utf8)), "no readable name leaves the device")
        try await mac.poll()
        guard case .waitingForResponder(let peer) = await mac.phase() else { return XCTFail("the request is frozen") }
        XCTAssertEqual(peer.displayName, "Pocket Phone")

        // A name the sender did not clean is cleaned by the receiver.
        let payload = PairingRequestPayload(sessionID: qr.sessionID, card: try DeviceCard.make(identity: phone.identity, platform: .iOS, createdAt: harness.clock.now()),
                                            commitment: Data(repeating: 0x5A, count: 32), displayName: "")
        var raw = ByteWriter()
        raw.append(payload.sessionID.rawValue)
        raw.append(payload.card.bytes)
        raw.append(payload.commitment)
        raw.appendLengthPrefixed(Data("Evil\u{202E}\u{0007}Name".utf8))
        let decoded = try PairingRequestPayload(decoding: raw.data)
        XCTAssertEqual(decoded.displayName, "EvilName")
        var oversized = ByteWriter()
        oversized.append(payload.sessionID.rawValue)
        oversized.append(payload.card.bytes)
        oversized.append(payload.commitment)
        oversized.appendLengthPrefixed(Data(repeating: 0x61, count: 257))
        XCTAssertThrowsError(try PairingRequestPayload(decoding: oversized.data))
    }

    func testSecureEnclaveErrorsAreClassified() {
        func error(_ domain: String, _ code: Int, underlying: NSError? = nil) -> NSError {
            NSError(domain: domain, code: code, userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        let classify = SecureEnclaveDeviceIdentity.classify
        XCTAssertEqual(classify(error(LAErrorDomain, LAError.userCancel.rawValue)), .authenticationCancelled)
        XCTAssertEqual(classify(error(LAErrorDomain, LAError.systemCancel.rawValue)), .authenticationCancelled)
        XCTAssertEqual(classify(error(LAErrorDomain, LAError.authenticationFailed.rawValue)), .authenticationFailed)
        XCTAssertEqual(classify(error(LAErrorDomain, LAError.biometryNotEnrolled.rawValue)), .unusable)
        XCTAssertEqual(classify(error("CryptoTokenKit", -4)), .authenticationCancelled)
        XCTAssertEqual(classify(error("Wrapper", 1, underlying: error(LAErrorDomain, LAError.userCancel.rawValue))),
                       .authenticationCancelled)
        XCTAssertEqual(classify(error(NSOSStatusErrorDomain, -25300)), .unusable)
        XCTAssertEqual(classify(DeviceIdentityError.keyCreationFailed), .keyCreationFailed)
    }
}
