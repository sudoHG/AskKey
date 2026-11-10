import CryptoKit
import Foundation

public enum PairingQRPayloadError: Error, Equatable, Sendable {
    /// The text is not an Ask Key pairing code.
    case notAPairingCode
    /// The text starts with the prefix but does not decode to a version 1
    /// payload with valid keys.
    case malformed
    /// The code's expiry has passed.
    case expired
}

/// The QR code the initiator shows (ADR 0013 → Pairing, step 1): the text
/// prefix `ASKKEY-PAIR1:` followed by unpadded Base64url of the binary
/// payload, 123 bytes:
///
///     version (1) || session ID (16) || pairing secret (32) || QR expiry (8)
///     || the initiator's message and key-agreement public keys (33 bytes each, compressed)
///
/// It is not a URL and holds no names. The text is 177 characters.
public struct PairingQRPayload: Hashable, Sendable {
    public static let prefix = "ASKKEY-PAIR1:"
    public static let version: UInt8 = 1
    public static let byteCount = 123
    public static let textLength = 177
    public static let maximumTextLength = 200

    public let sessionID: PairingSessionID
    let secret: Data
    public let qrExpiry: Date
    public let initiatorMessageKey: P256.Signing.PublicKey
    public let initiatorAgreementKey: P256.KeyAgreement.PublicKey
    /// The exact binary payload, which the transcript hash covers.
    public let bytes: Data

    /// Builds a payload from its fields. The pairing secret must be 32 bytes.
    public init(sessionID: PairingSessionID, secret: Data, qrExpiry: Date,
                initiatorMessageKey: P256.Signing.PublicKey, initiatorAgreementKey: P256.KeyAgreement.PublicKey) {
        precondition(secret.count == 32, "the pairing secret is 32 bytes")
        var writer = ByteWriter()
        writer.append(Self.version)
        writer.append(sessionID.rawValue)
        writer.append(secret)
        writer.appendTime(UnixTime.seconds(qrExpiry))
        writer.append(initiatorMessageKey.compressedRepresentation)
        writer.append(initiatorAgreementKey.compressedRepresentation)
        self.sessionID = sessionID
        self.secret = Data(secret)
        self.qrExpiry = UnixTime.date(UnixTime.seconds(qrExpiry))
        self.initiatorMessageKey = initiatorMessageKey
        self.initiatorAgreementKey = initiatorAgreementKey
        bytes = writer.data
    }

    /// Decodes scanned text strictly. It does not check the expiry.
    public init(text: String) throws {
        guard text.hasPrefix(Self.prefix) else { throw PairingQRPayloadError.notAPairingCode }
        guard text.utf8.count == Self.textLength,
              let binary = Base64URL.decode(String(text.dropFirst(Self.prefix.count))),
              binary.count == Self.byteCount else {
            throw PairingQRPayloadError.malformed
        }
        var reader = ByteReader(binary)
        do {
            guard try reader.readByte() == Self.version,
                  let sessionID = PairingSessionID(rawValue: try reader.readBytes(16)) else {
                throw MalformedEncoding()
            }
            let secret = try reader.readBytes(32)
            let expiry = try reader.readTime()
            let messageKey = try P256.Signing.PublicKey(compressedRepresentation: try reader.readBytes(33))
            let agreementKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: try reader.readBytes(33))
            try reader.finish()
            guard messageKey.compressedRepresentation != agreementKey.compressedRepresentation else {
                throw MalformedEncoding()
            }
            self.init(sessionID: sessionID, secret: secret, qrExpiry: UnixTime.date(expiry),
                      initiatorMessageKey: messageKey, initiatorAgreementKey: agreementKey)
        } catch {
            throw PairingQRPayloadError.malformed
        }
    }

    public var text: String { Self.prefix + Base64URL.encode(bytes) }

    /// The initiator's device ID, derived from its message key.
    public var initiatorID: DeviceID { DeviceID(messagePublicKey: initiatorMessageKey) }

    var preSharedKey: HPKEPreSharedKey {
        HPKEPreSharedKey(key: PairingDerivation.preSharedKey(secret: secret, sessionID: sessionID),
                         identifier: sessionID.rawValue)
    }

    public static func == (lhs: PairingQRPayload, rhs: PairingQRPayload) -> Bool { lhs.bytes == rhs.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

/// The pairing derivations of ADR 0013 → Pairing. They are pure functions,
/// public so that their fixed test vectors can be checked.
public enum PairingDerivation {
    /// HKDF-SHA256 over the pairing secret, with the session ID as salt and
    /// `AskKey pairing psk v1\0` as info, 32 bytes.
    public static func preSharedKey(secret: Data, sessionID: PairingSessionID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: sessionID.rawValue,
                               info: DomainLabel.pairingPreSharedKey, outputByteCount: 32)
    }

    /// The responder's commitment: SHA-256 over
    /// `AskKey pairing commitment v1\0`, the session ID and the 32-byte
    /// secret it reveals after the challenge.
    public static func commitment(sessionID: PairingSessionID, secret: Data) -> Data {
        Data(SHA256.hash(data: DomainLabel.pairingCommitment + sessionID.rawValue + secret))
    }

    /// SHA-256 over `AskKey pairing transcript v1\0`, the binary QR payload,
    /// the responder's card, its commitment, the initiator's card, the nonce
    /// and the revealed secret.
    public static func transcriptHash(qrPayload: Data, responderCard: Data, commitment: Data, initiatorCard: Data,
                                      nonce: Data, revealedSecret: Data) -> Data {
        var hash = SHA256()
        hash.update(data: DomainLabel.pairingTranscript)
        hash.update(data: qrPayload)
        hash.update(data: responderCard)
        hash.update(data: commitment)
        hash.update(data: initiatorCard)
        hash.update(data: nonce)
        hash.update(data: revealedSecret)
        return Data(hash.finalize())
    }

    /// The first 4 bytes of HKDF-SHA256 over the pairing secret, with the
    /// transcript hash as salt and `AskKey comparison code v1\0` as info,
    /// read as a big-endian integer modulo 1,000,000.
    public static func comparisonCode(secret: Data, transcriptHash: Data) -> PairingCode {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: transcriptHash,
                                         info: DomainLabel.comparisonCode, outputByteCount: 4)
        let value = key.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
        return PairingCode(value: value % 1_000_000)
    }

    /// The first 16 bytes of SHA-256 over `AskKey pairing id v1\0` and the
    /// transcript hash.
    public static func pairingID(transcriptHash: Data) -> PairingID {
        PairingID(rawValue: Data(SHA256.hash(data: DomainLabel.pairingID + transcriptHash).prefix(16)))!
    }
}
