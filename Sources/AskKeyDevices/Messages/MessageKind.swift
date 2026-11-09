import Foundation

/// The CloudKit record type a message is written as. `AlertMessage` may show
/// a notification on an iPhone; `QuietMessage` never does.
public enum MessageRecordType: String, Hashable, Sendable, CaseIterable {
    case alert = "AlertMessage"
    case quiet = "QuietMessage"
}

/// The stage 2 message kinds and what ADR 0013 → Sealed messages fixes for
/// each: the record type, the HPKE mode, and the longest allowed lifetime.
public enum MessageKind: UInt8, Hashable, Sendable, CaseIterable {
    case pairingRequest = 1
    case pairingChallenge = 2
    case pairingConfirmation = 3
    case pairingCancellation = 4
    case pairingWithdrawal = 5
    case unpairNotice = 6
    case deliveryCheck = 7
    case deliveryCheckReply = 8

    /// Pairing messages live at most as long as a session.
    public static let pairingLifetime: TimeInterval = 10 * 60
    public static let deliveryCheckLifetime: TimeInterval = 10 * 60
    public static let unpairNoticeLifetime: TimeInterval = 30 * 24 * 60 * 60

    public var recordType: MessageRecordType {
        self == .deliveryCheck ? .alert : .quiet
    }

    /// Pairing requests and withdrawals use HPKE PSK mode; every other kind
    /// uses base mode.
    public var usesPreSharedKey: Bool {
        self == .pairingRequest || self == .pairingWithdrawal
    }

    public var isPairing: Bool { rawValue <= MessageKind.pairingWithdrawal.rawValue }

    public var maximumLifetime: TimeInterval {
        switch self {
        case .pairingRequest, .pairingChallenge, .pairingConfirmation, .pairingCancellation, .pairingWithdrawal:
            return Self.pairingLifetime
        case .deliveryCheck, .deliveryCheckReply:
            return Self.deliveryCheckLifetime
        case .unpairNotice:
            return Self.unpairNoticeLifetime
        }
    }
}

/// One message as the transport carries it: the CloudKit record's plaintext
/// fields and its HPKE body. Every plaintext field is a routing hint that the
/// recipient checks against the signed message after decryption.
public struct DeviceEnvelope: Hashable, Sendable {
    public var recordType: MessageRecordType
    /// The message ID in Base32.
    public var recordName: String
    /// The sender's device ID in Base32.
    public var sender: String
    /// The recipient's device ID in Base32; its inbox holds the record.
    public var recipient: String
    public var kind: Int64
    public var sentAt: Date
    public var expiresAt: Date
    /// Body version (1) || HPKE encapsulated key (65) || HPKE ciphertext.
    public var body: Data

    public init(recordType: MessageRecordType, recordName: String, sender: String, recipient: String,
                kind: Int64, sentAt: Date, expiresAt: Date, body: Data) {
        self.recordType = recordType
        self.recordName = recordName
        self.sender = sender
        self.recipient = recipient
        self.kind = kind
        self.sentAt = sentAt
        self.expiresAt = expiresAt
        self.body = body
    }
}

/// Why a message was refused. Refusals are never reported to the sender, and
/// callers log them without content.
public enum DeviceMessageRefusal: Error, Hashable, Sendable {
    /// A field, payload or body does not have the specified layout.
    case malformed
    case unknownKind
    /// The record type is not the one ADR 0013 gives for the kind.
    case recordTypeMismatch
    case wrongRecipient
    case decryptionFailed
    case badSignature
    /// A plaintext record field differs from the signed one.
    case routingMismatch
    case expired
    case sentInFuture
    case lifetimeTooLong
    /// The sender is not on the paired-device list and not the peer of an
    /// open pairing session.
    case unknownSender
    /// The session ID, request digest, transcript hash, role, signer, pairing
    /// ID or delivery check does not match this device's state.
    case bindingMismatch
    case replayed
    /// No open pairing session can take this message.
    case noSession
    /// This device's role in the session never receives this kind.
    case unexpectedKind
    /// The pairing request was first fetched more than 30 seconds after the
    /// QR code expired.
    case requestTooLate
    /// The card reuses a key of this device or of another paired device.
    case keyConflict
    /// The message failed to process three times.
    case repeatedFailure
}
