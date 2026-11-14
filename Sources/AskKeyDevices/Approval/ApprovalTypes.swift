import Foundation

/// A decision code (ADR 0014 → Encodings). Every other value is reserved.
public enum ApprovalDecisionCode: UInt8, Hashable, Sendable, CaseIterable {
    case deny = 0
    case allowOnce = 1
    /// The timed allowance for the request's one credential.
    case timedAllowance = 2
}

/// The decision codes a request offers: bit *n* set means code *n* is
/// offered. Only Deny alone, Deny and Allow Once, or all three are valid.
public struct ApprovalOffers: Hashable, Sendable {
    public static let denyOnly = ApprovalOffers(valid: 0x01)
    public static let denyOrAllowOnce = ApprovalOffers(valid: 0x03)
    public static let all = ApprovalOffers(valid: 0x07)

    public let rawValue: UInt8

    public init?(rawValue: UInt8) {
        guard [0x01, 0x03, 0x07].contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(valid rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public func contains(_ code: ApprovalDecisionCode) -> Bool {
        rawValue & (1 << code.rawValue) != 0
    }
}

/// How a request ended for one approver, in an approval-closed message.
public enum ApprovalClosedOutcome: UInt8, Hashable, Sendable, CaseIterable {
    /// This approver's decision moved the request out of pending.
    case applied = 1
    case decidedOnMac = 2
    case decidedOnAnotherApprover = 3
    case expired = 4
    /// The agent cancelled, the credential changed, agent access was
    /// paused, or this approver was turned off or removed.
    case cancelled = 5
    /// The Mac verified the decision but could not apply it as signed.
    case notApplied = 6
}

/// One row of what a request hands over (field 18 of kind 10).
public struct ApprovalDeliveryRow: Hashable, Sendable {
    public enum Kind: UInt8, Hashable, Sendable {
        case environmentVariable = 1
        case temporaryFile = 2
    }

    public var kind: Kind
    /// The component's name for a bundle; empty for a single-material
    /// credential, which the iPhone then shows by the credential's name.
    public var label: String
    /// The variable's name; never empty.
    public var variable: String

    public init(kind: Kind, label: String, variable: String) {
        self.kind = kind
        self.label = label
        self.variable = variable
    }

    /// Kind (1) ‖ label (4 + bytes) ‖ variable (4 + bytes).
    var encodedByteCount: Int { 9 + label.utf8.count + variable.utf8.count }
}

/// Which display fields of a request the Mac shortened to fit their caps.
/// Bit *k* stands for field 11 + *k*; bit 6 also covers dropped rows.
public struct ApprovalShortenedFields: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let requesterName = ApprovalShortenedFields(rawValue: 1 << 0)
    public static let purpose = ApprovalShortenedFields(rawValue: 1 << 1)
    public static let credentialName = ApprovalShortenedFields(rawValue: 1 << 2)
    public static let commandLine = ApprovalShortenedFields(rawValue: 1 << 3)
    public static let workingDirectory = ApprovalShortenedFields(rawValue: 1 << 4)
    public static let executableName = ApprovalShortenedFields(rawValue: 1 << 5)
    /// A delivery row was shortened or dropped.
    public static let deliveryRows = ApprovalShortenedFields(rawValue: 1 << 6)
}

/// Why `AskKeyDevices` would not build or seal an approval message. Nothing
/// was sent.
public enum ApprovalMessageError: Error, Equatable, Sendable {
    /// The credential name, command line or executable name is empty, or a
    /// delivery row has no variable.
    case invalidDisplay
    /// The binding or request digest is not 32 bytes, or a binding string
    /// is over 4 KiB.
    case invalidDigest
    /// The timed duration does not fit the offers: 1–7,200 seconds when the
    /// timed allowance is offered, 0 otherwise.
    case invalidTimedDuration
    /// The deadline is not after the sending time or more than 300 seconds
    /// after it.
    case deadlineOutOfRange
    /// The verified message is not an approval request.
    case notARequest
    /// The request did not offer this decision code.
    case notOffered
    /// The closed message's applied code and duration do not fit its outcome.
    case invalidClosedOutcome
}

/// The rules shared by every kind 10–14 payload (ADR 0014 → Encodings):
/// each starts with the pairing ID and the layout version, and text fields
/// are length-prefixed UTF-8 without control or line-break characters.
enum ApprovalLayout {
    static let version: UInt8 = 1
    static let digestByteCount = 32
    static let signatureByteCount = 64
    /// The Broker's maximum timed allowance.
    static let maximumTimedDuration: UInt64 = 7_200
    /// A request's deadline is at most this long after its sent time.
    static let maximumDeadlineDelay: Int64 = 300
    /// A request's transport expiry is at most this long after its deadline.
    static let expiryAfterDeadline: Int64 = 300

    static func writeHeader(_ pairingID: PairingID, into writer: inout ByteWriter) {
        writer.append(pairingID.rawValue)
        writer.append(version)
    }

    /// Reads the pairing ID and refuses another layout version.
    static func readHeader(_ reader: inout ByteReader) throws -> PairingID {
        let pairingID = try MessagePayload.readPairingID(&reader)
        guard try reader.readByte() == version else { throw MalformedEncoding() }
        return pairingID
    }

    static func readDigest(_ reader: inout ByteReader) throws -> Data {
        try reader.readBytes(digestByteCount)
    }

    /// A text field of at most `cap` bytes that is valid UTF-8 and holds no
    /// scalar that `isDisplayControl` matches.
    static func readText(_ reader: inout ByteReader, cap: Int) throws -> String {
        let bytes = try reader.readLengthPrefixed(maximumCount: cap)
        let text = String(decoding: bytes, as: UTF8.self)
        // Decoding replaces invalid sequences, so the bytes differ unless they were valid UTF-8.
        guard Data(text.utf8) == bytes, !text.unicodeScalars.contains(where: isDisplayControl) else {
            throw MalformedEncoding()
        }
        return text
    }

    static func writeText(_ text: String, into writer: inout ByteWriter) {
        writer.appendLengthPrefixed(Data(text.utf8))
    }

    /// Foundation's `CharacterSet.controlCharacters` (Cc and Cf) and
    /// `CharacterSet.newlines`.
    static func isDisplayControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }

    static func isZero(_ bytes: Data) -> Bool {
        bytes.allSatisfy { $0 == 0 }
    }
}
