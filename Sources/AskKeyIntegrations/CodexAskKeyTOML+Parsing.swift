import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexAskKeyTOML {
    static func sections(in text: String) throws -> [Section] {
        if text.contains("\0") { throw CodexUserMCPError.illegalConfig }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        let sourceLines = lines(of: text, newline: newline)
        var scan = Scan.normal
        var sections: [Section] = []
        var raw = ""
        var body = ""
        var header: TableName?
        var isArray = false

        func push() {
            sections.append(Section(raw: raw, body: body, name: header, isArray: isArray, newline: newline))
            raw = ""
            body = ""
            header = nil
            isArray = false
        }

        for (index, line) in sourceLines.enumerated() {
            let isLast = index == sourceLines.count - 1
            let suffix = isLast && !text.hasSuffix(newline) ? "" : newline
            if scan.isNormal {
                let code = codePortion(line).trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("[") {
                    guard let parsed = parseHeader(code) else {
                        throw CodexUserMCPError.illegalConfig
                    }
                    if !raw.isEmpty || header != nil { push() }
                    header = parsed.name
                    isArray = parsed.isArray
                    if parsed.isArray && parsed.name.isAskKey {
                        throw CodexUserMCPError.illegalConfig
                    }
                    raw += line + suffix
                    continue
                }
                if !code.isEmpty, !code.contains("="), !code.hasPrefix("#") {
                    throw CodexUserMCPError.illegalConfig
                }
            }
            raw += line + suffix
            if header != nil { body += line + suffix }
            scan = advance(scan, through: line)
        }
        if !scan.isNormal { throw CodexUserMCPError.illegalConfig }
        if !raw.isEmpty || sections.isEmpty { push() }
        return sections
    }

    static func assertBalanced(_ text: String) throws {
        var index = text.startIndex
        var brackets = 0
        var braces = 0
        var inBasic = false
        var inLiteral = false
        var inBasicML = false
        var inLiteralML = false
        var escaped = false
        var inComment = false
        while index < text.endIndex {
            let character = text[index]
            if inComment {
                if character == "\n" { inComment = false }
                index = text.index(after: index)
                continue
            }
            if inBasicML {
                if text[index...].hasPrefix("\"\"\"") {
                    inBasicML = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inLiteralML {
                if text[index...].hasPrefix("'''") {
                    inLiteralML = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inBasic {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasic = false
                }
                index = text.index(after: index)
                continue
            }
            if inLiteral {
                if character == "'" { inLiteral = false }
                index = text.index(after: index)
                continue
            }
            if character == "#" {
                inComment = true
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix("\"\"\"") {
                inBasicML = true
                index = text.index(index, offsetBy: 3)
                continue
            }
            if text[index...].hasPrefix("'''") {
                inLiteralML = true
                index = text.index(index, offsetBy: 3)
                continue
            }
            if character == "\"" {
                inBasic = true
                index = text.index(after: index)
                continue
            }
            if character == "'" {
                inLiteral = true
                index = text.index(after: index)
                continue
            }
            if character == "[" { brackets += 1 }
            if character == "]" {
                brackets -= 1
                if brackets < 0 { throw CodexUserMCPError.illegalConfig }
            }
            if character == "{" { braces += 1 }
            if character == "}" {
                braces -= 1
                if braces < 0 { throw CodexUserMCPError.illegalConfig }
            }
            index = text.index(after: index)
        }
        if inBasic || inLiteral || inBasicML || inLiteralML || brackets != 0 || braces != 0 {
            throw CodexUserMCPError.illegalConfig
        }
    }

    private static func parseHeader(_ code: String) -> (name: TableName, isArray: Bool)? {
        var text = code
        var isArray = false
        if text.hasPrefix("[["), text.hasSuffix("]]") {
            isArray = true
            text = String(text.dropFirst(2).dropLast(2))
        } else if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        } else {
            return nil
        }
        guard let parts = dottedParts(text.trimmingCharacters(in: .whitespaces)), !parts.isEmpty else {
            return nil
        }
        return (TableName(parts: parts), isArray)
    }

    static func keyName(_ code: String) -> String? {
        guard let eq = code.firstIndex(of: "=") else { return nil }
        return String(code[..<eq]).trimmingCharacters(in: .whitespaces)
    }

    static func dottedParts(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
                else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "." {
                parts.append(current)
                current = ""
                continue
            }
            if character == " " { continue }
            current.append(character)
        }
        if quote != nil { return nil }
        parts.append(current)
        if parts.contains(where: \.isEmpty) { return nil }
        return parts
    }

    static func scalarValue(_ code: String) throws -> String {
        guard let eq = code.firstIndex(of: "=") else { throw CodexUserMCPError.illegalConfig }
        let raw = String(code[code.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
            return unescape(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'"), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        if raw.contains("#") {
            return try scalarValue(String(raw.split(separator: "#", maxSplits: 1)[0]).trimmingCharacters(in: .whitespaces))
        }
        return raw
    }

    static func arrayValue(_ code: String) throws -> [String] {
        guard let eq = code.firstIndex(of: "=") else { throw CodexUserMCPError.illegalConfig }
        return try arrayLiteral(String(code[code.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
    }

    static func arrayLiteral(_ raw: String) throws -> [String] {
        var text = raw
        if let comment = text.firstIndex(of: "#"), !text[..<comment].contains("\"") {
            text = String(text[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        guard text.hasPrefix("["), text.hasSuffix("]") else { throw CodexUserMCPError.illegalConfig }
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if inner.isEmpty { return [] }
        return try inner.split(separator: ",").map {
            try scalarValue("x = \($0.trimmingCharacters(in: .whitespaces))")
        }
    }

    static func inlineTable(_ code: String) -> [String: String]? {
        guard let start = code.firstIndex(of: "{"), code.hasSuffix("}") else { return nil }
        let inner = code[code.index(after: start)..<code.index(before: code.endIndex)]
        var values: [String: String] = [:]
        for piece in inner.split(separator: ",") {
            let item = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = item.firstIndex(of: "=") else { continue }
            let key = item[..<eq].trimmingCharacters(in: .whitespaces)
            values[key] = item[item.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    static func lines(of text: String, newline: String) -> [String] {
        if text.isEmpty { return [""] }
        var result: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(newline) {
                result.append(current)
                current = ""
                index = text.index(index, offsetBy: newline.count)
            } else {
                current.append(text[index])
                index = text.index(after: index)
            }
        }
        result.append(current)
        if text.hasSuffix(newline) { result.removeLast() }
        return result
    }

    static func codePortion(_ line: String) -> String {
        var quote: Character?
        var escaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if let current = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" && current == "\"" {
                    escaped = true
                } else if character == current {
                    quote = nil
                }
            } else if character == "#" {
                return String(line[..<index])
            } else if character == "\"" || character == "'" {
                quote = character
            }
            index = line.index(after: index)
        }
        return line
    }

    static func advance(_ scan: Scan, through line: String) -> Scan {
        var state = scan
        var brackets: Int
        var braces: Int
        switch state {
        case .normal:
            brackets = 0
            braces = 0
        case let .basicML(currentBrackets, currentBraces),
             let .literalML(currentBrackets, currentBraces),
             let .collections(currentBrackets, currentBraces):
            brackets = currentBrackets
            braces = currentBraces
        }
        var index = line.startIndex
        var escaped = false
        while index < line.endIndex {
            if case .basicML = state {
                let rest = line[index...]
                if rest.hasPrefix("\"\"\"") {
                    state = brackets == 0 && braces == 0
                        ? .normal
                        : .collections(brackets: brackets, braces: braces)
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
                continue
            }
            if case .literalML = state {
                let rest = line[index...]
                if rest.hasPrefix("'''") {
                    state = brackets == 0 && braces == 0
                        ? .normal
                        : .collections(brackets: brackets, braces: braces)
                    index = line.index(index, offsetBy: 3)
                } else {
                    index = line.index(after: index)
                }
                continue
            }

            if state.isNormal || (brackets > 0 || braces > 0) {
                let rest = line[index...]
                if rest.hasPrefix("\"\"\"") {
                    state = .basicML(brackets: brackets, braces: braces)
                    index = line.index(index, offsetBy: 3)
                    continue
                }
                if rest.hasPrefix("'''") {
                    state = .literalML(brackets: brackets, braces: braces)
                    index = line.index(index, offsetBy: 3)
                    continue
                }
                let character = line[index]
                if character == "#" { break }
                if character == "\"" || character == "'" {
                    let quote = character
                    index = line.index(after: index)
                    while index < line.endIndex {
                        let inner = line[index]
                        if escaped {
                            escaped = false
                        } else if inner == "\\" && quote == "\"" {
                            escaped = true
                        } else if inner == quote {
                            index = line.index(after: index)
                            break
                        }
                        index = line.index(after: index)
                    }
                    continue
                }
                if character == "[" {
                    brackets += 1
                } else if character == "]" {
                    brackets -= 1
                } else if character == "{" {
                    braces += 1
                } else if character == "}" {
                    braces -= 1
                }
            }
            index = line.index(after: index)
        }
        switch state {
        case .basicML, .literalML:
            return state
        case .normal, .collections:
            return brackets == 0 && braces == 0
                ? .normal
                : .collections(brackets: brackets, braces: braces)
        }
    }

    static func braceDelta(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1 == "{" ? 1 : $1 == "}" ? -1 : 0) }
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character == "n" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }
}
