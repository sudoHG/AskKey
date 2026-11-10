import Foundation

/// Lowercase RFC 4648 Base32 without padding, decoded canonically: only
/// lowercase letters and the digits 2–7, no padding, and zero unused bits,
/// so each byte string has exactly one text form.
enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
    private static let values: [UInt8: UInt8] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($0.element, UInt8($0.offset)) }
    )

    static func encode(_ data: Data) -> String {
        var output = [UInt8]()
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 0x1F)])
        }
        return String(decoding: output, as: UTF8.self)
    }

    static func decode(_ text: String, byteCount: Int) -> Data? {
        let characters = Array(text.utf8)
        guard characters.count == (byteCount * 8 + 4) / 5 else { return nil }
        var output = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in characters {
            guard let value = values[character] else { return nil }
            buffer = buffer << 5 | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        // The unused trailing bits must be zero.
        guard output.count == byteCount, buffer & ((1 << UInt32(bits)) - 1) == 0 else { return nil }
        return output
    }
}

/// Unpadded Base64url (RFC 4648 §5), decoded canonically.
enum Base64URL {
    private static let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        guard text.utf8.allSatisfy({ alphabet.contains($0) }), text.utf8.count % 4 != 1 else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), encode(data) == text else { return nil }
        return data
    }
}
