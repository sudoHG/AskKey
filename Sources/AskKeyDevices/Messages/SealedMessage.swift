import CryptoKit
import Foundation

/// The signed inner message (ADR 0013 → Encodings):
///
///     version (1) || kind (1) || sender ID (16) || recipient ID (16) || message ID (16)
///     || sent time (8) || expiry time (8) || payload length (4) || payload
///     || raw ECDSA signature (64) by the sender's message key over
///        "AskKey message v1\0" || every preceding byte
struct InnerMessage {
    static let version: UInt8 = 1
    static let maximumPayloadByteCount = 16 * 1024

    let kind: MessageKind
    let sender: DeviceID
    let recipient: DeviceID
    let messageID: MessageID
    let sentAt: Int64
    let expiresAt: Int64
    let payload: Data
    /// The exact bytes, signature included.
    let bytes: Data

    static func make(kind: MessageKind, sender: DeviceID, recipient: DeviceID, messageID: MessageID,
                     sentAt: Int64, expiresAt: Int64, payload: Data, identity: any DeviceIdentity) throws -> InnerMessage {
        var writer = ByteWriter()
        writer.append(version)
        writer.append(kind.rawValue)
        writer.append(sender.rawValue)
        writer.append(recipient.rawValue)
        writer.append(messageID.rawValue)
        writer.appendTime(sentAt)
        writer.appendTime(expiresAt)
        writer.appendLengthPrefixed(payload)
        writer.append(try identity.signWithMessageKey(DomainLabel.message + writer.data))
        return try InnerMessage(parsing: writer.data)
    }

    /// Parses the layout strictly. The signature is verified separately,
    /// once the sender's key is known.
    init(parsing bytes: Data) throws {
        var reader = ByteReader(bytes)
        guard try reader.readByte() == Self.version,
              let kind = MessageKind(rawValue: try reader.readByte()),
              let sender = DeviceID(rawValue: try reader.readBytes(16)),
              let recipient = DeviceID(rawValue: try reader.readBytes(16)),
              let messageID = MessageID(rawValue: try reader.readBytes(16)) else {
            throw MalformedEncoding()
        }
        let sentAt = try reader.readTime()
        let expiresAt = try reader.readTime()
        let payload = try reader.readLengthPrefixed(maximumCount: Self.maximumPayloadByteCount)
        _ = try reader.readBytes(64)
        try reader.finish()
        self.kind = kind
        self.sender = sender
        self.recipient = recipient
        self.messageID = messageID
        self.sentAt = sentAt
        self.expiresAt = expiresAt
        self.payload = payload
        self.bytes = Data(bytes)
    }

    /// Verifies the exact received bytes; nothing is re-serialized.
    func hasValidSignature(from key: P256.Signing.PublicKey) -> Bool {
        guard let signature = try? P256.Signing.ECDSASignature(rawRepresentation: bytes.suffix(64)) else {
            return false
        }
        return key.isValidSignature(signature, for: DomainLabel.message + bytes.dropLast(64))
    }

    /// SHA-256 over the exact bytes, signature included.
    var digest: Data { Data(SHA256.hash(data: bytes)) }
}

/// Seals and opens messages: the body is version (1) || the HPKE
/// encapsulated key (65, uncompressed P-256 point) || the HPKE ciphertext of
/// the inner message, with a new single-shot HPKE context per message.
enum MessageCodec {
    static let bodyVersion: UInt8 = 1
    static let hpkeInfoVersion: UInt8 = 1
    static let ciphersuite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let allowedClockSkew: Int64 = 5 * 60

    /// `AskKey HPKE v1\0` || version (1) || sender ID (16) || recipient ID (16).
    static func info(sender: DeviceID, recipient: DeviceID) -> Data {
        var writer = ByteWriter()
        writer.append(DomainLabel.hpkeInfo)
        writer.append(hpkeInfoVersion)
        writer.append(sender.rawValue)
        writer.append(recipient.rawValue)
        return writer.data
    }

    struct Sealed {
        let envelope: DeviceEnvelope
        let inner: InnerMessage
    }

    static func seal(kind: MessageKind, payload: Data, identity: any DeviceIdentity, recipient: DeviceID,
                     recipientKey: P256.KeyAgreement.PublicKey, preSharedKey: HPKEPreSharedKey?,
                     sentAt: Int64, expiresAt: Int64, messageID: MessageID = .random()) throws -> Sealed {
        precondition(kind.usesPreSharedKey == (preSharedKey != nil), "the HPKE mode follows from the kind")
        let sender = identity.deviceID
        let inner = try InnerMessage.make(kind: kind, sender: sender, recipient: recipient, messageID: messageID,
                                          sentAt: sentAt, expiresAt: expiresAt, payload: payload, identity: identity)
        let info = info(sender: sender, recipient: recipient)
        var context: HPKE.Sender
        if let preSharedKey {
            context = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: ciphersuite, info: info,
                                      presharedKey: preSharedKey.key, presharedKeyIdentifier: preSharedKey.identifier)
        } else {
            context = try HPKE.Sender(recipientKey: recipientKey, ciphersuite: ciphersuite, info: info)
        }
        let ciphertext = try context.seal(inner.bytes)
        precondition(context.encapsulatedKey.count == 65)
        let envelope = DeviceEnvelope(
            recordType: kind.recordType, recordName: messageID.text, sender: sender.text, recipient: recipient.text,
            kind: Int64(kind.rawValue), sentAt: UnixTime.date(sentAt), expiresAt: UnixTime.date(expiresAt),
            body: Data([bodyVersion]) + context.encapsulatedKey + ciphertext
        )
        return Sealed(envelope: envelope, inner: inner)
    }

    /// The plaintext routing hints, parsed canonically.
    struct Routing {
        let kind: MessageKind
        let sender: DeviceID
        let messageID: MessageID
        let sentAt: Int64
        let expiresAt: Int64
    }

    /// Checks the plaintext fields that need no key: a known kind, the record
    /// type for that kind, this device as recipient, canonical IDs and times,
    /// and an expiry that has not passed.
    static func routing(of envelope: DeviceEnvelope, ownID: DeviceID, now: Date) throws -> Routing {
        guard let rawKind = UInt8(exactly: envelope.kind), let kind = MessageKind(rawValue: rawKind) else {
            throw DeviceMessageRefusal.unknownKind
        }
        guard envelope.recordType == kind.recordType else { throw DeviceMessageRefusal.recordTypeMismatch }
        guard DeviceID(text: envelope.recipient) == ownID else { throw DeviceMessageRefusal.wrongRecipient }
        guard let sender = DeviceID(text: envelope.sender), let messageID = MessageID(text: envelope.recordName),
              let sentAt = UnixTime.exactSeconds(envelope.sentAt),
              let expiresAt = UnixTime.exactSeconds(envelope.expiresAt) else {
            throw DeviceMessageRefusal.malformed
        }
        guard expiresAt > UnixTime.seconds(now) else { throw DeviceMessageRefusal.expired }
        return Routing(kind: kind, sender: sender, messageID: messageID, sentAt: sentAt, expiresAt: expiresAt)
    }

    /// Decrypts the body with the HPKE info built from the plaintext sender
    /// and recipient, parses the inner message, and refuses any signed field
    /// that differs from the plaintext one and any time outside the kind's
    /// rules. Throws `DeviceMessageRefusal`, or `DeviceIdentityError` when
    /// this device's own key no longer works.
    static func open(_ envelope: DeviceEnvelope, routing: Routing, ownID: DeviceID, identity: any DeviceIdentity,
                     preSharedKey: HPKEPreSharedKey?, now: Date) throws -> InnerMessage {
        precondition(routing.kind.usesPreSharedKey == (preSharedKey != nil), "the HPKE mode follows from the kind")
        var reader = ByteReader(envelope.body)
        let encapsulatedKey: Data
        let ciphertext: Data
        do {
            guard try reader.readByte() == bodyVersion else { throw MalformedEncoding() }
            encapsulatedKey = try reader.readBytes(65)
            _ = try P256.KeyAgreement.PublicKey(x963Representation: encapsulatedKey)
            ciphertext = reader.readRemaining()
        } catch {
            throw DeviceMessageRefusal.malformed
        }
        let plaintext: Data
        do {
            plaintext = try identity.openHPKE(ciphertext, encapsulatedKey: encapsulatedKey,
                                              info: info(sender: routing.sender, recipient: ownID),
                                              preSharedKey: preSharedKey)
        } catch let error as DeviceIdentityError {
            throw error
        } catch {
            throw DeviceMessageRefusal.decryptionFailed
        }
        guard let inner = try? InnerMessage(parsing: plaintext) else { throw DeviceMessageRefusal.malformed }
        guard inner.kind == routing.kind, inner.sender == routing.sender, inner.recipient == ownID,
              inner.messageID == routing.messageID, inner.sentAt == routing.sentAt,
              inner.expiresAt == routing.expiresAt else {
            throw DeviceMessageRefusal.routingMismatch
        }
        let nowSeconds = UnixTime.seconds(now)
        guard inner.expiresAt > nowSeconds else { throw DeviceMessageRefusal.expired }
        guard inner.sentAt <= nowSeconds + allowedClockSkew else { throw DeviceMessageRefusal.sentInFuture }
        guard inner.expiresAt > inner.sentAt else { throw DeviceMessageRefusal.malformed }
        guard TimeInterval(inner.expiresAt - inner.sentAt) <= inner.kind.maximumLifetime else {
            throw DeviceMessageRefusal.lifetimeTooLong
        }
        return inner
    }
}
