import CryptoKit
import Foundation

/// The six-digit approver code of ADR 0014 → Approvers. The Mac draws it
/// and shows it as `123 456`; the person types it on the iPhone, which
/// sends only its code proof. It is never sent, logged or put in a
/// notification, so its description and mirror are redacted.
public struct ApproverCode: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                            CustomReflectable {
    /// 0 ..< 1,000,000.
    let value: UInt32

    init(value: UInt32) {
        precondition(value < 1_000_000)
        self.value = value
    }

    /// Drawn uniformly from 000000–999999 with the system's random number generator.
    public static func random() -> ApproverCode {
        var generator = SystemRandomNumberGenerator()
        return ApproverCode(value: UInt32.random(in: 0...999_999, using: &generator))
    }

    /// The code typed on the iPhone: exactly six ASCII digits once white
    /// space (the Unicode `White_Space` property) is removed; nil otherwise,
    /// and then nothing may be sent.
    public init?(typed text: String) {
        let scalars = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard scalars.count == 6, scalars.allSatisfy({ (0x30...0x39).contains($0.value) }) else { return nil }
        value = scalars.reduce(UInt32(0)) { $0 * 10 + ($1.value - 0x30) }
    }

    /// Six digits with leading zeros, such as `042917`.
    public var digits: String {
        let text = String(value)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// The digits in two groups of three, such as `042 917`.
    public var formatted: String { "\(digits.prefix(3)) \(digits.suffix(3))" }

    public var description: String { "ApproverCode(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// HMAC-SHA256 over the Mac's device ID ‖ the iPhone's device ID ‖ the
    /// pairing ID, keyed with HKDF-SHA256 of the six ASCII digits (salt: the
    /// pairing ID; info: `AskKey approver code v1\0`; 32 bytes).
    public func proof(mac: DeviceID, phone: DeviceID, pairingID: PairingID) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(digits.utf8)),
                                         salt: pairingID.rawValue, info: DomainLabel.approverCode, outputByteCount: 32)
        let code = HMAC<SHA256>.authenticationCode(for: mac.rawValue + phone.rawValue + pairingID.rawValue, using: key)
        return Data(code)
    }

    /// Whether a received proof is this code's proof for the three IDs. The
    /// comparison takes the same time wherever the proofs differ.
    public func matches(proof received: Data, mac: DeviceID, phone: DeviceID, pairingID: PairingID) -> Bool {
        let expected = proof(mac: mac, phone: phone, pairingID: pairingID)
        guard received.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (lhs, rhs) in zip(expected, received) {
            difference |= lhs ^ rhs
        }
        return difference == 0
    }
}
