import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

extension CursorUserMCPAdapter {
    func loadExistingObject() throws -> [String: Any]? {
        let info = try inspect(userConfigURL)
        if !info.exists { return nil }
        let bytes = try readRegularFile(userConfigURL)
        return bytes.isEmpty ? [:] : try decodeObject(bytes)
    }

    func mergeAskKey(into root: [String: Any]) -> [String: Any] {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["askkey"] = [
            "command": helperURL.path,
            "args": ["mcp"],
        ]
        root["mcpServers"] = servers
        return root
    }

    func makeDiff(existing: [String: Any]?, merged: [String: Any]) throws -> CursorMCPDiff {
        let before: String
        if let existing {
            before = String(decoding: try encode(redacted(existing)), as: UTF8.self)
        } else {
            before = ""
        }
        let after = String(decoding: try encode(redacted(merged)), as: UTF8.self)
        return CursorMCPDiff(before: before, after: after)
    }


    func inspect(_ url: URL) throws -> (exists: Bool, permissions: mode_t) {
        var st = stat()
        let result = url.path.withCString { lstat($0, &st) }
        if result != 0 {
            guard errno == ENOENT else { throw CursorMCPError.unsafeFile }
            return (false, 0)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw CursorMCPError.unsafeFile }
        return (true, st.st_mode & 0o777)
    }

    func readRegularFile(_ url: URL) throws -> Data {
        try readRegularFileSnapshot(url).bytes
    }

    func readRegularFileSnapshot(
        _ url: URL
    ) throws -> (bytes: Data, permissions: mode_t) {
        do {
            let file = try ClientConfigFileIO.readRegularFile(url)
            return (file.bytes, file.mode)
        } catch ClientConfigFileIO.Failure.notFound, ClientConfigFileIO.Failure.unsafe {
            throw CursorMCPError.unsafeFile
        } catch {
            throw CursorMCPError.replaceFailed
        }
    }

    func decodeObject(_ data: Data) throws -> [String: Any] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CursorMCPError.invalidJSON
        }
        guard let object = json as? [String: Any] else { throw CursorMCPError.invalidJSON }
        if let servers = object["mcpServers"], (servers as? [String: Any]) == nil {
            throw CursorMCPError.invalidJSON
        }
        return object
    }

    func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func redacted(_ value: [String: Any]) -> [String: Any] {
        var output: [String: Any] = [:]
        for (key, child) in value {
            if isSensitiveKey(key) {
                output[key] = "***"
            } else {
                output[key] = redactedValue(child)
            }
        }
        return output
    }

    private func redactedValue(_ value: Any) -> Any {
        if let nested = value as? [String: Any] { return redacted(nested) }
        if let array = value as? [Any] { return array.map(redactedValue) }
        return value
    }

    private func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "env" || normalized == "headers"
            || ["token", "secret", "password", "authorization", "apikey", "credential", "cookie"]
                .contains(where: normalized.contains)
    }

    private func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    func isExecutableRegularFile(_ url: URL) -> Bool {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }
        return true
    }
}
