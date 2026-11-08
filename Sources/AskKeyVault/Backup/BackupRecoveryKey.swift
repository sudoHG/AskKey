import CryptoKit
import Foundation

public enum BackupRecoveryKeyError: Error, Equatable, Sendable {
    /// After removing spaces and hyphens, the text is not 28 Crockford Base32 symbols.
    case malformed
    /// The symbols are well formed but the checksum does not match: a typo.
    case checksumMismatch
}

/// The key that opens one backup file: 128 random bits followed by a 12-bit
/// CRC, written as 28 Crockford Base32 symbols in seven groups of four.
///
/// Every export generates a new key and Ask Key never stores it. The checksum
/// lets a typo be reported before any decryption; CRC-12 detects every
/// single-symbol substitution and every adjacent transposition, because each
/// is a burst of at most 10 bits in the 140-bit codeword.
public struct BackupRecoveryKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let secretByteCount = 16
    static let symbolCount = 28
    private static let checksumBitCount = 12
    // CRC-12: x^12 + x^11 + x^3 + x^2 + x + 1, without the x^12 term.
    private static let checksumPolynomial: UInt16 = 0x080F
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    let secret: SymmetricKey
    /// The display form, for example `ABCD-EFGH-…`; show it once and never store it.
    public let groupedText: String

    static func generate() -> BackupRecoveryKey {
        BackupRecoveryKey(secret: SymmetricKey(size: .bits128))
    }

    private init(secret: SymmetricKey) {
        self.secret = secret
        let bytes = secret.withUnsafeBytes { [UInt8]($0) }
        precondition(bytes.count == Self.secretByteCount)
        var bits = bytes.flatMap { Self.bits(of: UInt16($0), count: 8) }
        bits += Self.bits(of: Self.checksum(bytes), count: Self.checksumBitCount)
        let symbols = stride(from: 0, to: bits.count, by: 5).map { start in
            Self.alphabet[Int(bits[start..<start + 5].reduce(0) { $0 << 1 | $1 })]
        }
        groupedText = stride(from: 0, to: symbols.count, by: 4)
            .map { String(decoding: symbols[$0..<$0 + 4], as: UTF8.self) }
            .joined(separator: "-")
    }

    /// Parses typed or pasted text. Case, whitespace and hyphens are ignored;
    /// `I` and `L` read as `1` and `O` reads as `0`.
    public init(parsing text: String) throws {
        var values: [UInt8] = []
        for scalar in text.unicodeScalars {
            if scalar == "-" || CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            guard values.count < Self.symbolCount, let value = Self.value(of: scalar) else {
                throw BackupRecoveryKeyError.malformed
            }
            values.append(value)
        }
        guard values.count == Self.symbolCount else { throw BackupRecoveryKeyError.malformed }
        let bits = values.flatMap { Self.bits(of: UInt16($0), count: 5) }
        let secretBitCount = Self.secretByteCount * 8
        let bytes = stride(from: 0, to: secretBitCount, by: 8).map { start in
            UInt8(bits[start..<start + 8].reduce(0) { $0 << 1 | $1 })
        }
        let checksum = bits[secretBitCount...].reduce(UInt16(0)) { $0 << 1 | UInt16($1) }
        guard checksum == Self.checksum(bytes) else { throw BackupRecoveryKeyError.checksumMismatch }
        self.init(secret: SymmetricKey(data: bytes))
    }

    // Printing, interpolating or dumping the key never shows it.
    public var description: String { "BackupRecoveryKey(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    private static func value(of scalar: Unicode.Scalar) -> UInt8? {
        guard scalar.isASCII else { return nil }
        var byte = UInt8(scalar.value)
        if (97...122).contains(byte) { byte -= 32 }
        switch byte {
        case UInt8(ascii: "O"): return 0
        case UInt8(ascii: "I"), UInt8(ascii: "L"): return 1
        default: return alphabet.firstIndex(of: byte).map(UInt8.init)
        }
    }

    private static func bits(of value: UInt16, count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8((value >> UInt16($0)) & 1) }
    }

    /// The remainder of the secret, multiplied by x^12, modulo the CRC-12 polynomial.
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var register: UInt16 = 0
        for byte in bytes {
            for shift in stride(from: 7, through: 0, by: -1) {
                let feedback = (register >> 11 ^ UInt16(byte >> UInt8(shift))) & 1
                register = register << 1 & 0x0FFF
                if feedback == 1 { register ^= checksumPolynomial }
            }
        }
        return register
    }
}
