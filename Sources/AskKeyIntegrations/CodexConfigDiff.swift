import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

public struct CodexConfigDiff: Equatable, Sendable {
    public let before: String
    public let after: String

    public var redactedDescription: String {
        "--- before\n\(redactCodexTOML(before))\n+++ after\n\(redactCodexTOML(after))"
    }
}

private func redactCodexTOML(_ text: String) -> String {
    redactCodexLineValues(redactMultilineStrings(text))
}

private func redactMultilineStrings(_ text: String) -> String {
    var result = ""
    var index = text.startIndex
    var inComment = false
    var inBasic = false
    var inLiteral = false
    var escaped = false
    while index < text.endIndex {
        let character = text[index]
        if inComment {
            result.append(character)
            if character == "\n" { inComment = false }
            index = text.index(after: index)
            continue
        }
        if inBasic {
            result.append(character)
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
            result.append(character)
            if character == "'" { inLiteral = false }
            index = text.index(after: index)
            continue
        }
        if character == "#" {
            inComment = true
            result.append(character)
            index = text.index(after: index)
            continue
        }
        if text[index...].hasPrefix("\"\"\"") {
            result.append("\"\"\"***\"\"\"")
            index = text.index(index, offsetBy: 3)
            while index < text.endIndex, !text[index...].hasPrefix("\"\"\"") {
                index = text.index(after: index)
            }
            if index < text.endIndex {
                index = text.index(index, offsetBy: 3)
            }
            continue
        }
        if text[index...].hasPrefix("'''") {
            result.append("'''***'''")
            index = text.index(index, offsetBy: 3)
            while index < text.endIndex, !text[index...].hasPrefix("'''") {
                index = text.index(after: index)
            }
            if index < text.endIndex {
                index = text.index(index, offsetBy: 3)
            }
            continue
        }
        if character == "\"" {
            inBasic = true
            result.append(character)
            index = text.index(after: index)
            continue
        }
        if character == "'" {
            inLiteral = true
            result.append(character)
            index = text.index(after: index)
            continue
        }
        result.append(character)
        index = text.index(after: index)
    }
    return result
}

private func redactCodexLineValues(_ text: String) -> String {
    text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line in
        redactCodexLine(String(line))
    }.joined(separator: "\n")
}

private func redactCodexLine(_ raw: String) -> String {
    var quoted = ""
    var index = raw.startIndex
    while index < raw.endIndex {
        let character = raw[index]
        if character == "\"" || character == "'" {
            quoted.append(character)
            quoted.append("***")
            let quote = character
            index = raw.index(after: index)
            var escaped = false
            while index < raw.endIndex {
                let inner = raw[index]
                index = raw.index(after: index)
                if escaped {
                    escaped = false
                    continue
                }
                if inner == "\\", quote == "\"" {
                    escaped = true
                    continue
                }
                if inner == quote { break }
            }
            quoted.append(quote)
            continue
        }
        quoted.append(character)
        index = raw.index(after: index)
    }
    guard let eq = quoted.firstIndex(of: "=") else { return quoted }
    let valueStart = quoted.index(after: eq)
    var cursor = valueStart
    while cursor < quoted.endIndex, quoted[cursor] == " " || quoted[cursor] == "\t" {
        cursor = quoted.index(after: cursor)
    }
    guard cursor < quoted.endIndex else { return quoted }
    let head = quoted[cursor]
    if head == "\"" || head == "'" || head == "[" || head == "{" || head == "#" {
        return quoted
    }
    var comment = quoted.endIndex
    var scan = cursor
    while scan < quoted.endIndex {
        if quoted[scan] == "#" {
            comment = scan
            break
        }
        scan = quoted.index(after: scan)
    }
    return String(quoted[..<cursor]) + "***" + String(quoted[comment...])
}
