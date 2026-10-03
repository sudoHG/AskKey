import Foundation

public enum EnvFileFormatError: Error, Equatable, LocalizedError, Sendable {
    case invalidLine(line: Int)
    case invalidKey(line: Int)
    case duplicateKey(line: Int)
    case unterminatedQuote(line: Int)
    case invalidEscape(line: Int)
    case trailingCharacters(line: Int)
    case multilineValue(line: Int)

    public var localizationKey: String {
        switch self {
        case .invalidLine:
            return "env.import.invalidLine"
        case .invalidKey:
            return "env.import.invalidKey"
        case .duplicateKey:
            return "env.import.duplicateKey"
        case .unterminatedQuote:
            return "env.import.unterminatedQuote"
        case .invalidEscape:
            return "env.import.invalidEscape"
        case .trailingCharacters:
            return "env.import.trailingCharacters"
        case .multilineValue:
            return "env.import.multilineValue"
        }
    }

    public var lineNumber: Int {
        switch self {
        case .invalidLine(let line),
             .invalidKey(let line),
             .duplicateKey(let line),
             .unterminatedQuote(let line),
             .invalidEscape(let line),
             .trailingCharacters(let line),
             .multilineValue(let line):
            return line
        }
    }

    /// Fallback text for callers that have not connected the app's
    /// localization table yet. It contains no key or value from the file.
    public var errorDescription: String? {
        switch self {
        case .invalidLine:
            return "The .env file contains an invalid assignment."
        case .invalidKey:
            return "The .env file contains an invalid variable name."
        case .duplicateKey:
            return "The .env file contains a duplicate variable name."
        case .unterminatedQuote:
            return "The .env file contains an unterminated quoted value."
        case .invalidEscape:
            return "The .env file contains an unsupported escape sequence."
        case .trailingCharacters:
            return "The .env file contains unexpected text after a quoted value."
        case .multilineValue:
            return "Multiline quoted values are not supported in .env imports."
        }
    }
}

public enum EnvFileFormat {
    public static func line(name: String, value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\(name)=\"\(escaped)\""
    }

    /// Parse the contents of a `.env` file into ordered key/value pairs.
    ///
    /// This is the historical non-throwing entry point. It keeps the old
    /// behavior of ignoring blank, comment, missing-key, and keyless lines;
    /// any other malformed input returns no partial result. New import paths
    /// should use `parseValidated(_:)` so the caller can show a precise error.
    public static func parse(_ content: String) -> [(name: String, value: String)] {
        do {
            return try parseLines(content, skipLegacyKeylessLines: true, validateKeys: false)
        } catch {
            return []
        }
    }

    /// Parse a `.env` file without silently changing or discarding a value.
    ///
    /// Supported syntax is one assignment per line, optional `export`, bare
    /// or single/double quoted values, trailing comments, and the escapes
    /// emitted by `line(name:value:)`. Quoted values cannot span lines.
    public static func parseValidated(_ content: String) throws -> [(name: String, value: String)] {
        try parseLines(content, skipLegacyKeylessLines: false, validateKeys: true)
    }

    private static func parseLines(
        _ content: String,
        skipLegacyKeylessLines: Bool,
        validateKeys: Bool
    ) throws -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        var seenKeys = Set<String>()
        let lines = content.components(separatedBy: .newlines)

        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("export") {
                let suffix = line.dropFirst("export".count)
                if suffix.first?.isWhitespace == true {
                    line = String(suffix).trimmingCharacters(in: .whitespaces)
                }
            }

            guard let equals = line.firstIndex(of: "=") else {
                if skipLegacyKeylessLines { continue }
                throw EnvFileFormatError.invalidLine(line: lineNumber)
            }

            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                if skipLegacyKeylessLines { continue }
                throw EnvFileFormatError.invalidKey(line: lineNumber)
            }
            if validateKeys && !isValidKey(key) {
                throw EnvFileFormatError.invalidKey(line: lineNumber)
            }
            if seenKeys.contains(key) {
                throw EnvFileFormatError.duplicateKey(line: lineNumber)
            }

            let valueStart = line.index(after: equals)
            let value = try parseValue(
                String(line[valueStart...]),
                line: lineNumber,
                hasFollowingLine: offset + 1 < lines.count
            )
            result.append((name: key, value: value))
            seenKeys.insert(key)
        }
        return result
    }

    private static func parseValue(
        _ rawValue: String,
        line: Int,
        hasFollowingLine: Bool
    ) throws -> String {
        let leadingTrimmed = rawValue.drop(while: { $0.isWhitespace })
        guard let first = leadingTrimmed.first else { return "" }

        if first == "#", rawValue.first?.isWhitespace == true {
            return ""
        }

        if first == "\"" || first == "'" {
            return try parseQuoted(
                String(leadingTrimmed),
                quote: first,
                line: line,
                hasFollowingLine: hasFollowingLine
            )
        }

        let bare = stripTrailingComment(from: String(leadingTrimmed))
        return bare.trimmingCharacters(in: .whitespaces)
    }

    private static func parseQuoted(
        _ source: String,
        quote: Character,
        line: Int,
        hasFollowingLine: Bool
    ) throws -> String {
        let characters = Array(source)
        var index = 1
        var result = ""

        while index < characters.count {
            let character = characters[index]
            if character == quote {
                let tail = String(characters[(index + 1)...])
                let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
                if trimmedTail.isEmpty || trimmedTail.first == "#" {
                    return result
                }
                throw EnvFileFormatError.trailingCharacters(line: line)
            }

            if quote == "\"" && character == "\\" {
                guard index + 1 < characters.count else {
                    throw EnvFileFormatError.invalidEscape(line: line)
                }
                index += 1
                switch characters[index] {
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: throw EnvFileFormatError.invalidEscape(line: line)
                }
            } else {
                result.append(character)
            }
            index += 1
        }

        if hasFollowingLine {
            throw EnvFileFormatError.multilineValue(line: line)
        }
        throw EnvFileFormatError.unterminatedQuote(line: line)
    }

    private static func stripTrailingComment(from value: String) -> String {
        let characters = Array(value)
        guard let index = characters.indices.dropFirst().first(where: { index in
            characters[index] == "#" && characters[index - 1].isWhitespace
        }) else {
            return value
        }
        return String(characters[..<index])
    }

    private static func isValidKey(_ key: String) -> Bool {
        let scalars = Array(key.unicodeScalars)
        guard let first = scalars.first,
              first.value == 0x5F || (0x41...0x5A).contains(first.value) || (0x61...0x7A).contains(first.value) else {
            return false
        }
        return scalars.dropFirst().allSatisfy {
            $0.value == 0x5F
                || (0x30...0x39).contains($0.value)
                || (0x41...0x5A).contains($0.value)
                || (0x61...0x7A).contains($0.value)
        }
    }
}
