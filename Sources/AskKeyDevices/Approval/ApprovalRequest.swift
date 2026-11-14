import Foundation

/// Kind 10, the approval request a Mac seals for one approver (ADR 0014 →
/// Encodings). Field order:
///
///     pairing ID (16) ‖ layout version (1) ‖ response ID (16) ‖ binding digest (32)
///     ‖ request deadline (8) ‖ launch time (8) ‖ offers (1) ‖ timed duration (8)
///     ‖ display flags (1) ‖ shortened flags (1)
///     ‖ requester name (4 + ≤ 256) ‖ purpose (4 + ≤ 1,024) ‖ credential name (4 + ≤ 1,024)
///     ‖ command line (4 + ≤ 6,144) ‖ working directory (4 + ≤ 1,024) ‖ executable name (4 + ≤ 256)
///     ‖ delivery row count (1, 0–64) ‖ delivery rows (≤ 3,072 in all)
///
/// Every text field is preformatted plain text: the iPhone shows it as it
/// is and refuses control and line-break characters instead of escaping.
public struct ApprovalRequest: Hashable, Sendable {
    /// The fixed fields, before the first text field.
    public static let fixedByteCount = 92
    /// Every field at its cap.
    public static let maximumByteCount = 12_917
    public static let maximumRowCount = 64
    public static let maximumRowsByteCount = 3_072

    /// The byte caps of fields 11–16 and of a row's label and variable.
    public enum Cap {
        public static let requesterName = 256
        public static let purpose = 1_024
        public static let credentialName = 1_024
        public static let commandLine = 6_144
        public static let workingDirectory = 1_024
        public static let executableName = 256
        public static let rowLabel = 256
        public static let rowVariable = 256
    }

    public let pairingID: PairingID
    /// Random and new for every sealed request; the decision's message ID.
    public let responseID: MessageID
    public let bindingDigest: Data
    /// The Broker request's expiry on the Mac's clock, in whole seconds.
    public let deadline: Date
    /// When the Mac App process that sealed the request started.
    public let launchTime: Date
    public let offers: ApprovalOffers
    /// Seconds, 1–7,200 when the timed allowance is offered; otherwise 0.
    public let timedDuration: UInt64
    /// The card's "this run will be refused" case; the request has no rows.
    public let deliveryMetadataUnavailable: Bool
    public let shortened: ApprovalShortenedFields
    /// Empty when absent; the iPhone then shows its own "Local Agent".
    public let requesterName: String
    public let purpose: String
    public let credentialName: String
    public let commandLine: String
    public let workingDirectory: String
    public let executableName: String
    public let deliveryRows: [ApprovalDeliveryRow]
    /// The exact payload bytes.
    public let encoded: Data

    let deadlineSeconds: Int64

    struct Fields {
        var pairingID: PairingID
        var responseID: MessageID
        var bindingDigest: Data
        var deadline: Int64
        var launchTime: Int64
        var offers: UInt8
        var timedDuration: UInt64
        var displayFlags: UInt8
        var shortenedFlags: UInt8
        var texts: [String]
        var rows: [ApprovalDeliveryRow]

        /// Writes the layout as given; `ApprovalRequest(decoding:)` decides
        /// whether it is valid.
        var encoded: Data {
            var writer = ByteWriter()
            ApprovalLayout.writeHeader(pairingID, into: &writer)
            writer.append(responseID.rawValue)
            writer.append(bindingDigest)
            writer.appendTime(deadline)
            writer.appendTime(launchTime)
            writer.append(offers)
            writer.appendUInt64(timedDuration)
            writer.append(displayFlags)
            writer.append(shortenedFlags)
            for text in texts { ApprovalLayout.writeText(text, into: &writer) }
            writer.append(UInt8(truncatingIfNeeded: rows.count))
            for row in rows {
                writer.append(row.kind.rawValue)
                ApprovalLayout.writeText(row.label, into: &writer)
                ApprovalLayout.writeText(row.variable, into: &writer)
            }
            return writer.data
        }
    }

    private static let textCaps = [Cap.requesterName, Cap.purpose, Cap.credentialName, Cap.commandLine,
                                   Cap.workingDirectory, Cap.executableName]

    /// Parses and checks the layout strictly. Throws
    /// `DeviceMessageRefusal.malformed` for another layout version, a
    /// reserved value, a field over its cap, text that is not valid UTF-8 or
    /// holds a control or line-break character, an empty credential name,
    /// command line, executable name or row variable, a timed duration that
    /// does not fit the offers, rows despite unavailable delivery metadata,
    /// more than 64 rows or 3,072 row bytes, trailing bytes, or a shortened
    /// field or unavailable metadata with anything but Deny offered.
    public init(decoding payload: Data) throws {
        self = try MessagePayload.decode(payload) { reader in
            let pairingID = try ApprovalLayout.readHeader(&reader)
            guard let responseID = MessageID(rawValue: try reader.readBytes(MessageID.byteCount)) else {
                throw MalformedEncoding()
            }
            let binding = try ApprovalLayout.readDigest(&reader)
            let deadline = try reader.readTime()
            let launchTime = try reader.readTime()
            guard let offers = ApprovalOffers(rawValue: try reader.readByte()) else { throw MalformedEncoding() }
            let timedDuration = try reader.readUInt64()
            let timedFits = offers.contains(.timedAllowance)
                ? (1...ApprovalLayout.maximumTimedDuration).contains(timedDuration) : timedDuration == 0
            let displayFlags = try reader.readByte()
            let shortenedFlags = try reader.readByte()
            guard timedFits, displayFlags & ~0x01 == 0, shortenedFlags & 0x80 == 0 else { throw MalformedEncoding() }
            var texts: [String] = []
            for cap in Self.textCaps { texts.append(try ApprovalLayout.readText(&reader, cap: cap)) }
            guard !texts[2].isEmpty, !texts[3].isEmpty, !texts[5].isEmpty else { throw MalformedEncoding() }
            let metadataUnavailable = displayFlags & 0x01 != 0
            let rowCount = Int(try reader.readByte())
            guard rowCount <= Self.maximumRowCount, !metadataUnavailable || rowCount == 0 else { throw MalformedEncoding() }
            var rows: [ApprovalDeliveryRow] = []
            var rowBytes = 0
            for _ in 0..<rowCount {
                guard let kind = ApprovalDeliveryRow.Kind(rawValue: try reader.readByte()) else { throw MalformedEncoding() }
                let row = ApprovalDeliveryRow(kind: kind, label: try ApprovalLayout.readText(&reader, cap: Cap.rowLabel),
                                              variable: try ApprovalLayout.readText(&reader, cap: Cap.rowVariable))
                rowBytes += row.encodedByteCount
                guard !row.variable.isEmpty, rowBytes <= Self.maximumRowsByteCount else { throw MalformedEncoding() }
                rows.append(row)
            }
            guard (shortenedFlags == 0 && !metadataUnavailable) || offers == .denyOnly else { throw MalformedEncoding() }
            return ApprovalRequest(pairingID: pairingID, responseID: responseID, bindingDigest: binding, deadline: deadline,
                                   launchTime: launchTime, offers: offers, timedDuration: timedDuration,
                                   metadataUnavailable: metadataUnavailable,
                                   shortened: ApprovalShortenedFields(rawValue: shortenedFlags), texts: texts, rows: rows,
                                   encoded: Data(payload))
        }
    }

    private init(pairingID: PairingID, responseID: MessageID, bindingDigest: Data, deadline: Int64, launchTime: Int64,
                 offers: ApprovalOffers, timedDuration: UInt64, metadataUnavailable: Bool,
                 shortened: ApprovalShortenedFields, texts: [String], rows: [ApprovalDeliveryRow], encoded: Data) {
        self.pairingID = pairingID
        self.responseID = responseID
        self.bindingDigest = bindingDigest
        deadlineSeconds = deadline
        self.deadline = UnixTime.date(deadline)
        self.launchTime = UnixTime.date(launchTime)
        self.offers = offers
        self.timedDuration = timedDuration
        deliveryMetadataUnavailable = metadataUnavailable
        self.shortened = shortened
        requesterName = texts[0]
        purpose = texts[1]
        credentialName = texts[2]
        commandLine = texts[3]
        workingDirectory = texts[4]
        executableName = texts[5]
        deliveryRows = rows
        self.encoded = encoded
    }

    /// The request's times against its inner message's: the deadline lies
    /// after the sent time and at most 300 seconds after it (else
    /// `malformed`), and the transport expiry at most 300 seconds after the
    /// deadline (else `lifetimeTooLong`).
    func checkTimes(sentAt: Int64, expiresAt: Int64) -> DeviceMessageRefusal? {
        guard deadlineSeconds > sentAt, deadlineSeconds - sentAt <= ApprovalLayout.maximumDeadlineDelay else {
            return .malformed
        }
        guard expiresAt <= deadlineSeconds + ApprovalLayout.expiryAfterDeadline else { return .lifetimeTooLong }
        return nil
    }

    /// The transport expiry a request sealed at `sentAt` gets: the deadline
    /// plus 5 minutes, at most 10 minutes after the sent time.
    static func expiry(sentAt: Int64, deadline: Int64) -> Int64 {
        min(deadline + ApprovalLayout.expiryAfterDeadline, sentAt + Int64(MessageKind.approvalLifetime))
    }
}
