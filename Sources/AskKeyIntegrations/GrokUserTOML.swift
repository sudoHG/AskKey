import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

enum GrokUserTOML {
    enum Transport: Equatable {
        case missing
        case remote
        case stdio(command: String, args: [String])
        case other
    }

    struct Table {
        var header: String
        var body: String
    }

    static func parse(_ text: String) throws -> [Table] {
        if text.contains("\0") { throw GrokCLIAdapterError.invalidConfig }
        var tables: [Table] = []
        var header = ""
        var body: [String] = []
        var arrayDepth = 0
        var objectDepth = 0
        var inMultilineBasic = false
        var inMultilineLiteral = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if inMultilineBasic {
                body.append(line)
                if countUnescaped(line, delimiter: "\"\"\"") % 2 == 1 { inMultilineBasic = false }
                continue
            }
            if inMultilineLiteral {
                body.append(line)
                if line.contains("'''") { inMultilineLiteral = false }
                continue
            }
            let trimmed = trimComment(line)
            if arrayDepth == 0 && objectDepth == 0 {
                if let next = tableHeader(trimmed) {
                    if !header.isEmpty || !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tables.append(Table(header: header, body: body.joined(separator: "\n")))
                    } else if header.isEmpty && !body.isEmpty {
                        tables.append(Table(header: "", body: body.joined(separator: "\n")))
                    }
                    header = next
                    body = []
                    continue
                }
            }
            if trimmed.isEmpty {
                body.append(line)
                continue
            }
            if arrayDepth == 0 && objectDepth == 0 && !trimmed.contains("=") && !trimmed.hasPrefix("[") {
                throw GrokCLIAdapterError.invalidConfig
            }
            if let idx = trimmed.firstIndex(of: "="), arrayDepth == 0, objectDepth == 0 {
                let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                if !value.hasPrefix("\""), value.contains("[[") { throw GrokCLIAdapterError.invalidConfig }
                if value.hasPrefix("[[") { throw GrokCLIAdapterError.invalidConfig }
                if value.contains("\"\"\"") { inMultilineBasic = countUnescaped(value, delimiter: "\"\"\"") % 2 == 1 }
                if value.contains("'''") { inMultilineLiteral = true }
            }
            arrayDepth += count(trimmed, of: "[") - count(trimmed, of: "]")
            objectDepth += count(trimmed, of: "{") - count(trimmed, of: "}")
            if arrayDepth < 0 || objectDepth < 0 { throw GrokCLIAdapterError.invalidConfig }
            body.append(line)
        }
        if inMultilineBasic || inMultilineLiteral || arrayDepth != 0 || objectDepth != 0 {
            throw GrokCLIAdapterError.invalidConfig
        }
        if !header.isEmpty || !body.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tables.append(Table(header: header, body: body.joined(separator: "\n")))
        }
        return tables
    }

    static func upsertStdio(
        in text: String,
        serverName: String,
        command: String,
        args: [String],
        env: [String: String]
    ) throws -> String {
        let tables = try parse(text)
        let prefixes = [
            "mcp_servers.\(serverName)",
            "mcp_servers.\(serverName).",
        ]
        var kept: [Table] = []
        for table in tables {
            if table.header == prefixes[0] || table.header.hasPrefix(prefixes[1]) { continue }
            kept.append(table)
        }
        var rendered = kept.map { table -> String in
            if table.header.isEmpty { return table.body }
            let heading = "[\(table.header)]"
            return table.body.trimmingCharacters(in: .newlines).isEmpty
                ? heading
                : heading + "\n" + table.body.trimmingCharacters(in: CharacterSet.newlines)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
        var section = """
        [mcp_servers.\(serverName)]
        command = \(quote(command))
        args = [\(args.map(quote).joined(separator: ", "))]
        enabled = true
        """
        if !env.isEmpty {
            let pairs = env.sorted(by: { $0.key < $1.key })
                .map { "\($0.key) = \(quote($0.value))" }
                .joined(separator: ", ")
            section += "\nenv = { \(pairs) }"
        }
        if !rendered.isEmpty { rendered += "\n\n" }
        rendered += section
        if !rendered.hasSuffix("\n") { rendered += "\n" }
        return rendered
    }

    static func askKeyTransport(in text: String, serverName: String = "askkey") -> Transport {
        guard let tables = try? parse(text) else { return .other }
        let header = "mcp_servers.\(serverName)"
        guard let table = tables.first(where: { $0.header == header }) else { return .missing }
        var command: String?
        var remote = false
        var args: [String] = []
        var collectingArgs = false
        var argsRaw = ""
        for raw in table.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = trimComment(String(raw))
            if collectingArgs {
                argsRaw += trimmed
                if trimmed.contains("]") {
                    collectingArgs = false
                    args = arrayValue(argsRaw)
                }
                continue
            }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key == "url" { remote = true }
            if key == "command" { command = unquote(value) }
            if key == "args" {
                argsRaw = value
                if value.contains("]") {
                    args = arrayValue(value)
                } else {
                    collectingArgs = true
                }
            }
        }
        if remote { return .remote }
        guard let command else { return .other }
        return .stdio(command: command, args: args)
    }

    static func redactedDiff(before: String, after: String) -> String {
        redact(before) == redact(after) ? "" : "before:\n\(redact(before))\n after:\n\(redact(after))\n"
    }

    private static func tableHeader(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { return nil }
        return String(trimmed.dropFirst().dropLast())
    }

    private static func arrayValue(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if trimmed.isEmpty { return [] }
        return trimmed.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func unquote(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
            value = value.replacingOccurrences(of: "\\\"", with: "\"")
            value = value.replacingOccurrences(of: "\\\\", with: "\\")
        }
        return value
    }

    private static func quote(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func trimComment(_ line: String) -> String {
        var inString = false
        var escaped = false
        for (index, character) in line.enumerated() {
            if escaped { escaped = false; continue }
            if character == "\\" && inString { escaped = true; continue }
            if character == "\"" { inString.toggle(); continue }
            if character == "#" && !inString {
                return String(line.prefix(index)).trimmingCharacters(in: .whitespaces)
            }
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func count(_ text: String, of character: Character) -> Int {
        var inString = false
        var escaped = false
        var total = 0
        for item in text {
            if escaped { escaped = false; continue }
            if item == "\\" && inString { escaped = true; continue }
            if item == "\"" { inString.toggle(); continue }
            if !inString && item == character { total += 1 }
        }
        return total
    }

    private static func countUnescaped(_ text: String, delimiter: String) -> Int {
        text.components(separatedBy: delimiter).count - 1
    }

    private static func redact(_ text: String) -> String {
        var insideEnvironmentTable = false
        var inlineEnvironmentDepth = 0
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let lower = line.lowercased()
            if inlineEnvironmentDepth > 0 {
                let structuralLine = trimComment(String(line))
                inlineEnvironmentDepth += count(structuralLine, of: "{")
                    - count(structuralLine, of: "}")
                inlineEnvironmentDepth = max(0, inlineEnvironmentDepth)
                return ""
            }
            if let header = tableHeader(trimComment(String(line)))?.lowercased() {
                insideEnvironmentTable = header.hasSuffix(".env") || header.contains(".env.")
                    || header.hasSuffix(".headers") || header.contains(".headers.")
                return String(line)
            }
            if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let normalizedKey = key.filter { $0.isLetter || $0.isNumber }
                if key == "env" || normalizedKey == "headers" {
                    let value = line[line.index(after: equals)...]
                    let structuralValue = trimComment(String(value))
                    inlineEnvironmentDepth = max(
                        0,
                        count(structuralValue, of: "{") - count(structuralValue, of: "}")
                    )
                    return String(line[..<equals]) + "= \"***\""
                }
            }
            if lower.contains("authorization") || lower.contains("token")
                || lower.contains("secret") || lower.contains("api_key")
                || lower.contains("x-api-key") || lower.contains("headers")
                || lower.contains("password") || lower.contains("askkey_broker_socket")
                || lower.contains(".env.") || lower.contains(".headers.")
                || insideEnvironmentTable {
                if let eq = line.firstIndex(of: "=") {
                    return String(line[..<eq]) + "= \"***\""
                }
            }
            return String(line)
        }.joined(separator: "\n")
    }
}
