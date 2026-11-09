import CryptoKit
import Foundation

/// A device's identifier: the first 16 bytes of SHA-256 over
/// `AskKey device id v1` and the message key's compressed public key. Inside
/// binary structures it is the 16 raw bytes; its text form, used for CloudKit
/// names and fields, is 26 characters of lowercase unpadded Base32. It is not
/// secret.
public struct DeviceID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public static let byteCount = 16

    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = Data(rawValue)
    }

    /// Accepts only the canonical text form.
    public init?(text: String) {
        guard let raw = Base32.decode(text, byteCount: Self.byteCount) else { return nil }
        rawValue = raw
    }

    public init(messagePublicKey: P256.Signing.PublicKey) {
        let digest = SHA256.hash(data: DomainLabel.deviceID + messagePublicKey.compressedRepresentation)
        rawValue = Data(digest.prefix(Self.byteCount))
    }

    public var text: String { Base32.encode(rawValue) }
    public var description: String { text }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool {
        lhs.rawValue.lexicographicallyPrecedes(rhs.rawValue)
    }
}

/// A message's random 16-byte identifier. The record name is its Base32 text.
public struct MessageID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16

    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = Data(rawValue)
    }

    public init?(text: String) {
        guard let raw = Base32.decode(text, byteCount: Self.byteCount) else { return nil }
        rawValue = raw
    }

    public static func random() -> MessageID {
        MessageID(rawValue: RandomBytes.make(byteCount))!
    }

    public var text: String { Base32.encode(rawValue) }
    public var description: String { text }
}

/// Identifies one pairing of two devices: the first 16 bytes of SHA-256 over
/// `AskKey pairing id v1` and the transcript hash. Pairing again creates a
/// new one, so messages bound to an earlier pairing are refused.
public struct PairingID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16

    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = Data(rawValue)
    }

    public var description: String { Base32.encode(rawValue) }
}

/// A pairing session's random 16-byte identifier; it is also the HKDF salt
/// and the HPKE pre-shared key ID of the session's PSK-mode messages.
public struct PairingSessionID: Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 16

    public let rawValue: Data

    public init?(rawValue: Data) {
        guard rawValue.count == Self.byteCount else { return nil }
        self.rawValue = Data(rawValue)
    }

    static func random() -> PairingSessionID {
        PairingSessionID(rawValue: RandomBytes.make(byteCount))!
    }

    public var description: String { Base32.encode(rawValue) }
}

enum RandomBytes {
    static func make(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}
