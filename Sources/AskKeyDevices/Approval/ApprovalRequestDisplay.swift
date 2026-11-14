import Foundation

/// What the Mac's card shows for a read request, as the App derives it
/// (ADR 0008): the display summary's command line, working directory and
/// executable name, which the Vault already shell-quoted and escaped, and
/// the rows the card's "Hands over" lists, in the card's order.
public struct ApprovalRequestDisplay: Hashable, Sendable {
    /// The Broker's sanitized caller name; empty when absent.
    public var requesterName: String
    public var purpose: String
    /// The trusted name the card shows; not empty.
    public var credentialName: String
    public var commandLine: String
    /// Home abbreviated; empty when absent.
    public var workingDirectory: String
    /// The card's last path component; not empty.
    public var executableName: String
    public var deliveryRows: [ApprovalDeliveryRow]
    /// The card's "this run will be refused" case. Rows are then not sent
    /// and only Deny is offered.
    public var deliveryMetadataUnavailable: Bool

    public init(requesterName: String, purpose: String, credentialName: String, commandLine: String,
                workingDirectory: String, executableName: String, deliveryRows: [ApprovalDeliveryRow],
                deliveryMetadataUnavailable: Bool = false) {
        self.requesterName = requesterName
        self.purpose = purpose
        self.credentialName = credentialName
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
        self.executableName = executableName
        self.deliveryRows = deliveryRows
        self.deliveryMetadataUnavailable = deliveryMetadataUnavailable
    }
}

extension ApprovalRequest {
    /// Builds the request one approver receives (ADR 0014 → Encodings).
    /// Every text field has the scalars of `CharacterSet.controlCharacters`
    /// and `CharacterSet.newlines` replaced with `\x` escapes of their UTF-8
    /// bytes (backslashes are left as they are), which changes nothing in
    /// text the Vault already escaped, and is then shortened to its cap.
    /// Rows are kept in order while they fit 64 rows and 3,072 bytes; the
    /// first that does not and every later one are dropped. Any shortened
    /// field or dropped row, or unavailable delivery metadata, makes the
    /// offers Deny only. Throws `ApprovalMessageError`.
    static func build(display: ApprovalRequestDisplay, pairingID: PairingID, responseID: MessageID, bindingDigest: Data,
                      deadline: Int64, launchTime: Int64, offers: ApprovalOffers,
                      timedDuration: UInt64) throws -> ApprovalRequest {
        guard bindingDigest.count == ApprovalLayout.digestByteCount else { throw ApprovalMessageError.invalidDigest }
        let timedFits = offers.contains(.timedAllowance)
            ? (1...ApprovalLayout.maximumTimedDuration).contains(timedDuration) : timedDuration == 0
        guard timedFits else { throw ApprovalMessageError.invalidTimedDuration }
        let inputs = [(display.requesterName, Cap.requesterName), (display.purpose, Cap.purpose),
                      (display.credentialName, Cap.credentialName), (display.commandLine, Cap.commandLine),
                      (display.workingDirectory, Cap.workingDirectory), (display.executableName, Cap.executableName)]
        var shortened = ApprovalShortenedFields()
        var texts: [String] = []
        for (index, (text, cap)) in inputs.enumerated() {
            let fitted = ApprovalText.fitted(text, cap: cap)
            if fitted.shortened { shortened.insert(ApprovalShortenedFields(rawValue: 1 << UInt8(index))) }
            texts.append(fitted.text)
        }
        guard !texts[2].isEmpty, !texts[3].isEmpty, !texts[5].isEmpty,
              display.deliveryMetadataUnavailable || display.deliveryRows.allSatisfy({ !$0.variable.isEmpty }) else {
            throw ApprovalMessageError.invalidDisplay
        }
        var rows: [ApprovalDeliveryRow] = []
        if !display.deliveryMetadataUnavailable {
            var rowBytes = 0
            for row in display.deliveryRows {
                let label = ApprovalText.fitted(row.label, cap: Cap.rowLabel)
                let variable = ApprovalText.fitted(row.variable, cap: Cap.rowVariable)
                let fitted = ApprovalDeliveryRow(kind: row.kind, label: label.text, variable: variable.text)
                guard rows.count < maximumRowCount, rowBytes + fitted.encodedByteCount <= maximumRowsByteCount else {
                    shortened.insert(.deliveryRows)
                    break
                }
                if label.shortened || variable.shortened { shortened.insert(.deliveryRows) }
                rows.append(fitted)
                rowBytes += fitted.encodedByteCount
            }
        }
        let denyOnly = !shortened.isEmpty || display.deliveryMetadataUnavailable
        let fields = Fields(pairingID: pairingID, responseID: responseID, bindingDigest: bindingDigest, deadline: deadline,
                            launchTime: launchTime, offers: denyOnly ? ApprovalOffers.denyOnly.rawValue : offers.rawValue,
                            timedDuration: denyOnly ? 0 : timedDuration,
                            displayFlags: display.deliveryMetadataUnavailable ? 0x01 : 0, shortenedFlags: shortened.rawValue,
                            texts: texts, rows: rows)
        // Whatever the Mac seals, the iPhone must accept.
        guard let request = try? ApprovalRequest(decoding: fields.encoded) else { throw ApprovalMessageError.invalidDisplay }
        return request
    }
}

/// The escaping and shortening of ADR 0014 → Encodings.
enum ApprovalText {
    static let ellipsis = "\u{2026}"

    /// Escapes, then shortens to `cap` bytes.
    static func fitted(_ text: String, cap: Int) -> (text: String, shortened: Bool) {
        shortened(escaped(text), cap: cap)
    }

    /// Replaces every scalar of `CharacterSet.controlCharacters` or
    /// `CharacterSet.newlines` with `\x` escapes of its UTF-8 bytes.
    static func escaped(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: ApprovalLayout.isDisplayControl) else { return text }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            guard ApprovalLayout.isDisplayControl(scalar) else {
                result.append(scalar)
                continue
            }
            for byte in String(scalar).utf8 {
                result.append(contentsOf: String(format: "\\x%02x", byte).unicodeScalars)
            }
        }
        return String(result)
    }

    /// A text over its cap becomes *P* ‖ `…` ‖ *S*: *P* is the longest
    /// prefix of whole scalars of at most ⌈(cap − 3) / 2⌉ bytes, *S* the
    /// longest suffix of whole scalars that fits the rest of the cap.
    static func shortened(_ text: String, cap: Int) -> (text: String, shortened: Bool) {
        guard text.utf8.count > cap else { return (text, false) }
        let budget = cap - ellipsis.utf8.count
        var prefix = String.UnicodeScalarView()
        var prefixBytes = 0
        for scalar in text.unicodeScalars {
            let width = UTF8.width(scalar)
            guard prefixBytes + width <= (budget + 1) / 2 else { break }
            prefix.append(scalar)
            prefixBytes += width
        }
        var suffix: [Unicode.Scalar] = []
        var suffixBytes = 0
        for scalar in text.unicodeScalars.reversed() {
            let width = UTF8.width(scalar)
            guard prefixBytes + suffixBytes + width <= budget else { break }
            suffix.append(scalar)
            suffixBytes += width
        }
        var result = prefix
        result.append(contentsOf: ellipsis.unicodeScalars)
        result.append(contentsOf: suffix.reversed())
        return (String(result), true)
    }
}
