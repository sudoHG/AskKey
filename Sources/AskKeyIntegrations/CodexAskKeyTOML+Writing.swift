import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    static func stripAskKeyKeys(from raw: String, newline: String) throws -> String {
        var kept: [String] = []
        var skippingBraces = 0
        let sourceLines = lines(of: raw, newline: newline)
        let endsWithNewline = raw.hasSuffix(newline)
        for (index, line) in sourceLines.enumerated() {
            let isLast = index == sourceLines.count - 1
            let suffix = isLast && !endsWithNewline ? "" : newline
            if skippingBraces > 0 {
                skippingBraces += braceDelta(line)
                continue
            }
            let code = codePortion(line).trimmingCharacters(in: .whitespaces)
            if let key = keyName(code), dottedParts(key)?.first == "askkey" {
                if code.contains("{") {
                    skippingBraces = braceDelta(code)
                    if skippingBraces > 0 { continue }
                }
                continue
            }
            kept.append(line + suffix)
        }
        return kept.joined()
    }

    static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
