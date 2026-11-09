import CryptoKit
import Foundation

/// What a device says about itself. The interface never presents it as
/// verified: nothing attests how a peer's keys are protected.
public enum DevicePlatform: UInt8, Hashable, Sendable {
    case macOS = 1
    case iOS = 2
}

public enum DeviceCardError: Error, Equatable, Sendable {
    /// The bytes do not have the version 1 layout, a key is not a valid
    /// P-256 point, or two of the card's keys are equal.
    case malformed
    /// The message key's signature over the card does not verify.
    case badSignature
}

/// A device card, version 1 (ADR 0013 → Encodings), 173 bytes:
///
///     version (1) || platform (1) || creation time (8, big-endian Unix seconds)
///     || message, key-agreement and approval public keys (33 bytes each, compressed)
///     || raw ECDSA signature (64) by the message key over
///        "AskKey device card v1\0" || every preceding byte
///
/// The device ID is derived from the message key, never stored in the card.
/// Display names are not in the card. A card is signed when a pairing
/// session starts, so its creation time is when it was signed.
public struct DeviceCard: Hashable, Sendable {
    public static let version: UInt8 = 1
    public static let byteCount = 173
    static let signedByteCount = byteCount - 64

    /// The exact bytes that were sent or received.
    public let bytes: Data
    public let platform: DevicePlatform
    public let createdAt: Date
    public let messagePublicKey: P256.Signing.PublicKey
    public let agreementPublicKey: P256.KeyAgreement.PublicKey
    public let approvalPublicKey: P256.Signing.PublicKey
    public let deviceID: DeviceID

    /// Parses and verifies a card strictly: the exact length and version, a
    /// known platform, three valid and distinct keys, and the signature.
    public init(bytes: Data) throws {
        var reader = ByteReader(bytes)
        do {
            guard try reader.readByte() == Self.version,
                  let platform = DevicePlatform(rawValue: try reader.readByte()) else {
                throw DeviceCardError.malformed
            }
            let created = try reader.readTime()
            let messageKey = try P256.Signing.PublicKey(compressedRepresentation: try reader.readBytes(33))
            let agreementKey = try P256.KeyAgreement.PublicKey(compressedRepresentation: try reader.readBytes(33))
            let approvalKey = try P256.Signing.PublicKey(compressedRepresentation: try reader.readBytes(33))
            let signature = try P256.Signing.ECDSASignature(rawRepresentation: try reader.readBytes(64))
            try reader.finish()
            let keys = [messageKey.compressedRepresentation, agreementKey.compressedRepresentation,
                        approvalKey.compressedRepresentation]
            guard Set(keys).count == 3 else { throw DeviceCardError.malformed }
            let exact = Data(bytes)
            guard messageKey.isValidSignature(signature, for: DomainLabel.deviceCard + exact.prefix(Self.signedByteCount)) else {
                throw DeviceCardError.badSignature
            }
            self.bytes = exact
            self.platform = platform
            createdAt = UnixTime.date(created)
            messagePublicKey = messageKey
            agreementPublicKey = agreementKey
            approvalPublicKey = approvalKey
            deviceID = DeviceID(messagePublicKey: messageKey)
        } catch let error as DeviceCardError {
            throw error
        } catch {
            throw DeviceCardError.malformed
        }
    }

    /// Signs a new card for this device with its message key.
    public static func make(identity: any DeviceIdentity, platform: DevicePlatform, createdAt: Date) throws -> DeviceCard {
        var writer = ByteWriter()
        writer.append(version)
        writer.append(platform.rawValue)
        writer.appendTime(UnixTime.seconds(createdAt))
        writer.append(identity.messagePublicKey.compressedRepresentation)
        writer.append(identity.agreementPublicKey.compressedRepresentation)
        writer.append(identity.approvalPublicKey.compressedRepresentation)
        let signature = try identity.signWithMessageKey(DomainLabel.deviceCard + writer.data)
        writer.append(signature)
        return try DeviceCard(bytes: writer.data)
    }

    /// The three compressed public keys.
    public var compressedPublicKeys: Set<Data> {
        [messagePublicKey.compressedRepresentation, agreementPublicKey.compressedRepresentation,
         approvalPublicKey.compressedRepresentation]
    }

    public static func == (lhs: DeviceCard, rhs: DeviceCard) -> Bool { lhs.bytes == rhs.bytes }
    public func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

/// Display names travel only inside sealed payloads. Both the sending and the
/// receiving side clean them before use (ADR 0013 → Encodings).
public enum DeviceDisplayName {
    public static let maximumScalarCount = 64
    public static let maximumByteCount = 256

    /// U+061C, U+200E, U+200F, U+202A–U+202E and U+2066–U+2069.
    private static let bidirectionalFormatting: Set<UInt32> = Set(
        [0x061C, 0x200E, 0x200F] + Array(0x202A...0x202E) + Array(0x2066...0x2069)
    )

    /// Removes control characters (category Cc) and the bidirectional
    /// formatting characters, trims surrounding white space, then keeps whole
    /// characters while the result stays within 64 Unicode scalars and 256
    /// UTF-8 bytes.
    public static func clean(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.unicodeScalars.filter {
            $0.properties.generalCategory != .control && !bidirectionalFormatting.contains($0.value)
        })
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var scalarCount = 0
        var byteCount = 0
        for character in trimmed {
            let characterScalars = character.unicodeScalars.count
            let characterBytes = character.utf8.count
            guard scalarCount + characterScalars <= maximumScalarCount,
                  byteCount + characterBytes <= maximumByteCount else { break }
            result.append(character)
            scalarCount += characterScalars
            byteCount += characterBytes
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
