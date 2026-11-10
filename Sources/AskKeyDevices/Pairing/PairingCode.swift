import Foundation

/// The six-digit pairing code of ADR 0013 → Pairing, step 4. Only the
/// responder shows it, as `123 456`; the initiator never exposes it and
/// only checks the code the person types against it.
///
/// Its description and mirror are redacted, so printing, dumping or logging
/// a phase never reveals the code; show `formatted` on the pairing screen.
public struct PairingCode: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                           CustomReflectable {
    /// 0 ..< 1,000,000.
    public let value: UInt32

    init(value: UInt32) {
        precondition(value < 1_000_000)
        self.value = value
    }

    /// Six digits with leading zeros, such as `012345`.
    public var digits: String {
        let text = String(value)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// The digits in two groups of three, such as `012 345`.
    public var formatted: String { "\(digits.prefix(3)) \(digits.suffix(3))" }

    public var description: String { "PairingCode(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// Whether the typed digits spell this code. The comparison takes the
    /// same time wherever the digits differ.
    func matches(_ entered: EnteredPairingCode) -> Bool {
        let expected = Array(digits.utf8)
        guard expected.count == entered.asciiDigits.count else { return false }
        var difference: UInt8 = 0
        for (expectedByte, enteredByte) in zip(expected, entered.asciiDigits) {
            difference |= expectedByte ^ enteredByte
        }
        return difference == 0
    }
}

/// The code a person typed on the initiator: exactly six ASCII digits once
/// white space (the Unicode `White_Space` property, which includes tabs,
/// line breaks and the full-width space) is removed. Anything else is
/// refused before it is compared, so it does not count as an attempt.
struct EnteredPairingCode {
    let asciiDigits: [UInt8]

    init?(_ text: String) {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard scalars.count == 6, scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else {
            return nil
        }
        asciiDigits = scalars.map { UInt8($0.value) }
    }
}
