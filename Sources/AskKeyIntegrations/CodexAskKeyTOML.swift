import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

enum CodexAskKeyTOML {
    static func validate(_ text: String) throws {
        try assertBalanced(text)
        try assertAssignmentsAndKeyPaths(try sections(in: text))
    }

    static func upsert(_ original: String, command: String, args: [String]) throws -> String {
        let parts = try sections(in: original)
        var kept = ""
        for part in parts {
            if part.name?.isAskKey == true { continue }
            if part.name?.isMCPServersRoot == true {
                kept += try stripAskKeyKeys(from: part.raw, newline: part.newline)
                continue
            }
            kept += part.raw
        }
        let table = """
        [mcp_servers.askkey]
        command = \(tomlString(command))
        args = [\(args.map(tomlString).joined(separator: ", "))]
        """
        if kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return table + "\n"
        }
        while kept.hasSuffix("\n\n") { kept.removeLast() }
        if !kept.hasSuffix("\n") { kept.append("\n") }
        return kept + "\n" + table + "\n"
    }

    static func hasServer(in text: String, named serverName: String) throws -> Bool {
        try validate(text)
        let target = ["mcp_servers", serverName]
        for part in try sections(in: text) {
            let tablePath = part.name?.parts ?? []
            if tablePath.starts(with: target) { return true }
            var scan = Scan.normal
            for line in lines(of: part.name == nil ? part.raw : part.body, newline: part.newline) {
                if scan.isNormal {
                    let code = codePortion(line)
                    if let key = keyName(code), let keyPath = dottedParts(key) {
                        let path = tablePath + keyPath
                        if path.starts(with: target) { return true }
                        if path == ["mcp_servers"], let equals = code.firstIndex(of: "=") {
                            let value = String(code[code.index(after: equals)...])
                            if inlineAssignmentPaths(value).contains(where: { $0.first == serverName }) {
                                return true
                            }
                        }
                    }
                }
                scan = advance(scan, through: line)
            }
        }
        return false
    }

    /// Splits only this inline table's assignments. Commas inside strings,
    /// nested tables and arrays cannot create a sibling server entry.
    private static func inlineAssignmentPaths(_ value: String) -> [[String]] {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "{", value.last == "}" else { return [] }
        var pieces: [String] = []
        var piece = ""
        var depth = 0
        var quote: Character?
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if let current = quote {
                piece.append(character)
                if escaped { escaped = false }
                else if character == "\\" && current == "\"" { escaped = true }
                else if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                piece.append(character)
            } else if character == "{" || character == "[" {
                depth += 1
                piece.append(character)
            } else if character == "}" || character == "]" {
                depth -= 1
                piece.append(character)
            } else if character == "," && depth == 0 {
                pieces.append(piece)
                piece = ""
            } else {
                piece.append(character)
            }
        }
        pieces.append(piece)
        return pieces.compactMap { assignment in
            keyName(assignment).flatMap(dottedParts)
        }
    }

    static func askKey(in text: String) throws -> (command: String, args: [String], enabled: Bool)? {
        let parts = try sections(in: text)
        var command: String?
        var args: [String]?
        var enabled = true
        for part in parts {
            if part.name?.isAskKey == true, part.name?.parts.count == 2 {
                for line in lines(of: part.body, newline: part.newline) {
                    let code = codePortion(line)
                    let trimmed = code.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("command") {
                        command = try scalarValue(trimmed)
                    } else if trimmed.hasPrefix("args") {
                        args = try arrayValue(trimmed)
                    } else if keyName(trimmed).flatMap(dottedParts) == ["enabled"] {
                        enabled = try scalarValue(trimmed) == "true"
                    }
                }
            }
            if part.name?.isMCPServersRoot == true {
                let stripped = try stripAskKeyKeys(from: part.raw, newline: part.newline)
                if stripped != part.raw {
                    // Inline askkey was present; parse it from the original body.
                    for line in lines(of: part.body, newline: part.newline) {
                        let code = codePortion(line).trimmingCharacters(in: .whitespaces)
                        if code.hasPrefix("askkey") || code.hasPrefix("\"askkey\"") {
                            if let inline = inlineTable(code) {
                                command = inline["command"]
                                if let rawArgs = inline["args"] {
                                    args = try arrayLiteral(rawArgs)
                                }
                                if let rawEnabled = inline["enabled"] {
                                    enabled = rawEnabled == "true"
                                }
                            }
                        }
                    }
                }
            }
        }
        guard let command, let args else { return nil }
        return (command, args, enabled)
    }

    static func preservesNonAskKey(original: String, current: String) throws -> Bool {
        let before = try sections(in: original)
            .filter { $0.name?.isAskKey != true }
            .map(\.raw)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = try sections(in: current)
            .filter { $0.name?.isAskKey != true }
            .map(\.raw)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return before == after
    }

}
