import Foundation

/// The payload layouts of the stage 2 kinds, fixed by #284. Fixed-size
/// fields are written as raw bytes; display names, the only variable-length
/// field, carry a 4-byte big-endian length prefix. IDs are 16 raw bytes.
///
///     1 pairing request       session ID (16) || responder card (173) || display name
///     2 pairing challenge     session ID (16) || request digest (32) || initiator card (173)
///                             || nonce (32) || display name
///     3 pairing confirmation  role (1) || signer ID (16) || transcript hash (32)
///                             || approval-key signature (64) over
///                                "AskKey pairing confirmation v1\0" || the preceding 49 bytes
///     4 pairing cancellation  session ID (16)
///     5 pairing withdrawal    session ID (16) || responder card (173)
///     6 unpair notice         pairing ID (16)
///     7 delivery check        pairing ID (16)
///     8 delivery check reply  pairing ID (16) || the check's message ID (16)
enum MessagePayload {
    static func decode<T>(_ payload: Data, _ body: (inout ByteReader) throws -> T) throws -> T {
        var reader = ByteReader(payload)
        do {
            let value = try body(&reader)
            try reader.finish()
            return value
        } catch let error as DeviceMessageRefusal {
            throw error
        } catch {
            throw DeviceMessageRefusal.malformed
        }
    }

    static func readSessionID(_ reader: inout ByteReader) throws -> PairingSessionID {
        guard let id = PairingSessionID(rawValue: try reader.readBytes(PairingSessionID.byteCount)) else {
            throw MalformedEncoding()
        }
        return id
    }

    static func readPairingID(_ reader: inout ByteReader) throws -> PairingID {
        guard let id = PairingID(rawValue: try reader.readBytes(PairingID.byteCount)) else { throw MalformedEncoding() }
        return id
    }

    static func readCard(_ reader: inout ByteReader) throws -> DeviceCard {
        let bytes = try reader.readBytes(DeviceCard.byteCount)
        do {
            return try DeviceCard(bytes: bytes)
        } catch DeviceCardError.badSignature {
            throw DeviceMessageRefusal.badSignature
        }
    }

    /// A name longer than the cleaning rule allows, or not UTF-8, is
    /// malformed; any other name is cleaned again before use.
    static func readDisplayName(_ reader: inout ByteReader) throws -> String {
        let bytes = try reader.readLengthPrefixed(maximumCount: DeviceDisplayName.maximumByteCount)
        guard let name = String(data: bytes, encoding: .utf8) else { throw MalformedEncoding() }
        return DeviceDisplayName.clean(name)
    }

    static func writeDisplayName(_ name: String, into writer: inout ByteWriter) {
        writer.appendLengthPrefixed(Data(DeviceDisplayName.clean(name).utf8))
    }
}

struct PairingRequestPayload {
    let sessionID: PairingSessionID
    let card: DeviceCard
    let displayName: String

    var encoded: Data {
        var writer = ByteWriter()
        writer.append(sessionID.rawValue)
        writer.append(card.bytes)
        MessagePayload.writeDisplayName(displayName, into: &writer)
        return writer.data
    }

    init(sessionID: PairingSessionID, card: DeviceCard, displayName: String) {
        self.sessionID = sessionID
        self.card = card
        self.displayName = displayName
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            PairingRequestPayload(sessionID: try MessagePayload.readSessionID(&reader),
                                  card: try MessagePayload.readCard(&reader),
                                  displayName: try MessagePayload.readDisplayName(&reader))
        }
    }
}

struct PairingChallengePayload {
    let sessionID: PairingSessionID
    let requestDigest: Data
    let card: DeviceCard
    let nonce: Data
    let displayName: String

    var encoded: Data {
        var writer = ByteWriter()
        writer.append(sessionID.rawValue)
        writer.append(requestDigest)
        writer.append(card.bytes)
        writer.append(nonce)
        MessagePayload.writeDisplayName(displayName, into: &writer)
        return writer.data
    }

    init(sessionID: PairingSessionID, requestDigest: Data, card: DeviceCard, nonce: Data, displayName: String) {
        self.sessionID = sessionID
        self.requestDigest = requestDigest
        self.card = card
        self.nonce = nonce
        self.displayName = displayName
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            PairingChallengePayload(sessionID: try MessagePayload.readSessionID(&reader),
                                    requestDigest: try reader.readBytes(32),
                                    card: try MessagePayload.readCard(&reader),
                                    nonce: try reader.readBytes(32),
                                    displayName: try MessagePayload.readDisplayName(&reader))
        }
    }
}

/// The role a side plays in a pairing session.
public enum PairingRole: UInt8, Hashable, Sendable {
    /// The Mac, which shows the QR code.
    case initiator = 1
    /// The device that scans the QR code.
    case responder = 2

    var other: PairingRole { self == .initiator ? .responder : .initiator }
}

struct PairingConfirmationPayload {
    static let signedFieldsByteCount = 1 + 16 + 32

    let role: PairingRole
    let signer: DeviceID
    let transcriptHash: Data
    let signature: Data
    /// The exact signed fields as received.
    let signedFields: Data

    /// The bytes the approval key signs.
    static func signedBytes(role: PairingRole, signer: DeviceID, transcriptHash: Data) -> Data {
        DomainLabel.pairingConfirmation + fields(role: role, signer: signer, transcriptHash: transcriptHash)
    }

    static func fields(role: PairingRole, signer: DeviceID, transcriptHash: Data) -> Data {
        var writer = ByteWriter()
        writer.append(role.rawValue)
        writer.append(signer.rawValue)
        writer.append(transcriptHash)
        return writer.data
    }

    static func encode(role: PairingRole, signer: DeviceID, transcriptHash: Data, signature: Data) -> Data {
        fields(role: role, signer: signer, transcriptHash: transcriptHash) + signature
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            guard let role = PairingRole(rawValue: try reader.readByte()),
                  let signer = DeviceID(rawValue: try reader.readBytes(16)) else {
                throw MalformedEncoding()
            }
            let transcriptHash = try reader.readBytes(32)
            let signature = try reader.readBytes(64)
            return PairingConfirmationPayload(role: role, signer: signer, transcriptHash: transcriptHash,
                                              signature: signature,
                                              signedFields: Data(payload.prefix(Self.signedFieldsByteCount)))
        }
    }

    private init(role: PairingRole, signer: DeviceID, transcriptHash: Data, signature: Data, signedFields: Data) {
        self.role = role
        self.signer = signer
        self.transcriptHash = transcriptHash
        self.signature = signature
        self.signedFields = signedFields
    }
}

/// The payload of a pairing cancellation.
struct PairingCancellationPayload {
    let sessionID: PairingSessionID

    var encoded: Data { sessionID.rawValue }

    init(sessionID: PairingSessionID) {
        self.sessionID = sessionID
    }

    init(decoding payload: Data) throws {
        sessionID = try MessagePayload.decode(payload) { try MessagePayload.readSessionID(&$0) }
    }
}

struct PairingWithdrawalPayload {
    let sessionID: PairingSessionID
    let card: DeviceCard

    var encoded: Data { sessionID.rawValue + card.bytes }

    init(sessionID: PairingSessionID, card: DeviceCard) {
        self.sessionID = sessionID
        self.card = card
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            PairingWithdrawalPayload(sessionID: try MessagePayload.readSessionID(&reader),
                                     card: try MessagePayload.readCard(&reader))
        }
    }
}

/// The payload of an unpair notice or a delivery check.
struct PairingIDPayload {
    let pairingID: PairingID

    var encoded: Data { pairingID.rawValue }

    init(pairingID: PairingID) {
        self.pairingID = pairingID
    }

    init(decoding payload: Data) throws {
        pairingID = try MessagePayload.decode(payload) { try MessagePayload.readPairingID(&$0) }
    }
}

struct DeliveryCheckReplyPayload {
    let pairingID: PairingID
    let checkMessageID: MessageID

    var encoded: Data { pairingID.rawValue + checkMessageID.rawValue }

    init(pairingID: PairingID, checkMessageID: MessageID) {
        self.pairingID = pairingID
        self.checkMessageID = checkMessageID
    }

    init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            let pairingID = try MessagePayload.readPairingID(&reader)
            guard let check = MessageID(rawValue: try reader.readBytes(16)) else { throw MalformedEncoding() }
            return DeliveryCheckReplyPayload(pairingID: pairingID, checkMessageID: check)
        }
    }
}
