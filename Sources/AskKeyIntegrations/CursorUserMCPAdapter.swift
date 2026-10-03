import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

private struct CursorRollbackBackup: Codable {
    let generationID: UUID
    let originalExisted: Bool
    let originalPermissions: UInt16
    let originalBytes: Data
    var replacementDigest: Data
}

private struct CursorConfigSnapshot {
    let existed: Bool
    let permissions: mode_t
    let bytes: Data
    let quarantineURL: URL?
}

private final class CursorBackupOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var generationID: UUID?

    func set(_ generationID: UUID) {
        lock.withLock { self.generationID = generationID }
    }

    func matches(_ generationID: UUID) -> Bool {
        lock.withLock { self.generationID == generationID }
    }
}

public enum CursorMCPError: Error, Equatable, LocalizedError {
    case unsafeFile
    case invalidJSON
    case replaceFailed
    case readbackFailed
    case rollbackFailed
    case backupCleanupFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeFile:
            return "Ask Key will not write a Cursor MCP config that is a symbolic link or special file."
        case .invalidJSON:
            return "The Cursor MCP config is not valid JSON, so it was left unchanged."
        case .replaceFailed:
            return "Ask Key could not replace the Cursor MCP config."
        case .readbackFailed:
            return "The Cursor MCP config could not be verified after writing."
        case .rollbackFailed:
            return "Ask Key could not restore the original Cursor MCP config. The managed backup was kept for recovery."
        case .backupCleanupFailed:
            return "Ask Key verified Cursor, but could not remove the managed backup. The connection was not marked successful."
        }
    }
}

public struct CursorMCPDiff: Equatable, Sendable {
    public let before: String
    public let after: String
}

public struct CursorMCPConnectionStatus: Equatable, Sendable {
    public let connected: Bool
    public let configReady: Bool
    public let helperReady: Bool
    public let protocolReady: Bool
    public let brokerHealthy: Bool
}

public struct CursorUserMCPAdapter {
    private static let processBackupLock = NSLock()
    public let userConfigURL: URL
    private let backupDirectory: URL
    private let helperURL: URL
    private let signing: CodexHelperSigning
    private let brokerSocketPath: String
    private let replaceConfig: (URL, URL) throws -> Void
    private let removeConfig: (URL) throws -> Void
    private let moveConfigExclusively: (URL, URL) throws -> Void
    private let removeBackupItem: (URL) throws -> Void
    private let backupOwnership = CursorBackupOwnership()

    public init(
        homeDirectory: URL,
        backupDirectory: URL,
        helperURL: URL,
        brokerSocketPath: String,
        signing: CodexHelperSigning = .executable,
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil
    ) {
        self.backupDirectory = backupDirectory
        self.helperURL = helperURL
        self.signing = signing
        self.brokerSocketPath = brokerSocketPath
        self.userConfigURL = homeDirectory.appendingPathComponent(".cursor/mcp.json")
        self.replaceConfig = replaceConfig ?? Self.renameExclusively
        self.removeConfig = removeConfig ?? { try FileManager.default.removeItem(at: $0) }
        self.moveConfigExclusively = moveConfigExclusively ?? Self.renameExclusively
        self.removeBackupItem = removeBackupItem ?? { try FileManager.default.removeItem(at: $0) }
    }

    private var backupURL: URL {
        backupDirectory.appendingPathComponent("cursor-mcp.json")
    }

    private var backupLockURL: URL {
        backupDirectory.deletingLastPathComponent().appendingPathComponent(".cursor.lock")
    }

    /// Presence includes stale or incomplete entries that still need repair.
    public func hasConfiguration() throws -> Bool {
        let object = try loadExistingObject()
        return (object?["mcpServers"] as? [String: Any])?["askkey"] != nil
    }

    public func preview() throws -> CursorMCPDiff {
        let existing = try loadExistingObject()
        return try makeDiff(existing: existing, merged: mergeAskKey(into: existing ?? [:]))
    }

    @discardableResult
    public func apply() throws -> CursorMCPDiff {
        try withBackupLock { try applyLocked() }
    }

    private func applyLocked() throws -> CursorMCPDiff {
        let snapshot = try takeConfigSnapshot()
        do {
            let existing = snapshot.existed
                ? (snapshot.bytes.isEmpty ? [:] : try decodeObject(snapshot.bytes))
                : nil
            let merged = mergeAskKey(into: existing ?? [:])
            let diff = try makeDiff(existing: existing, merged: merged)
            let bytes = try encode(merged)
            let backup = try prepareBackup(
                originalExisted: snapshot.existed,
                originalPermissions: snapshot.permissions,
                originalBytes: snapshot.bytes,
                replacementBytes: bytes
            )
            do {
                try writeAtomically(
                    bytes: bytes,
                    mode: snapshot.existed ? snapshot.permissions : 0o600,
                    replace: replaceConfig
                )
            } catch {
                try restoreInputSnapshot(snapshot)
                throw error
            }
            if let quarantineURL = snapshot.quarantineURL {
                try FileManager.default.removeItem(at: quarantineURL)
            }
            do {
                try readBack(expectedMode: snapshot.existed ? snapshot.permissions : 0o600)
            } catch {
                let failure = error
                do {
                    guard try readBackup().generationID == backup.generationID else {
                        throw CursorMCPError.rollbackFailed
                    }
                    try restore(backup)
                } catch {
                    throw CursorMCPError.rollbackFailed
                }
                throw failure
            }
            return diff
        } catch let error as CursorMCPError {
            try restoreInputSnapshot(snapshot)
            throw error
        } catch {
            try restoreInputSnapshot(snapshot)
            throw CursorMCPError.replaceFailed
        }
    }

    private func restoreInputSnapshot(_ snapshot: CursorConfigSnapshot) throws {
        guard let quarantineURL = snapshot.quarantineURL,
              FileManager.default.fileExists(atPath: quarantineURL.path) else { return }
        guard !FileManager.default.fileExists(atPath: userConfigURL.path) else {
            throw CursorMCPError.rollbackFailed
        }
        do {
            try moveConfigExclusively(quarantineURL, userConfigURL)
        } catch {
            throw CursorMCPError.rollbackFailed
        }
    }

    private func takeConfigSnapshot() throws -> CursorConfigSnapshot {
        let info = try inspect(userConfigURL)
        guard info.exists else {
            return CursorConfigSnapshot(
                existed: false,
                permissions: 0,
                bytes: Data(),
                quarantineURL: nil
            )
        }
        let quarantine = userConfigURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-input-\(UUID().uuidString)")
        try moveConfigExclusively(userConfigURL, quarantine)
        do {
            let frozen = try readRegularFileSnapshot(quarantine)
            return CursorConfigSnapshot(
                existed: true,
                permissions: frozen.permissions,
                bytes: frozen.bytes,
                quarantineURL: quarantine
            )
        } catch {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw error
        }
    }

    public func verify() throws -> CursorMCPConnectionStatus {
        try withBackupLock { try verifyLocked() }
    }

    private func verifyLocked() throws -> CursorMCPConnectionStatus {
        let status = try status()
        if status.connected, FileManager.default.fileExists(atPath: backupURL.path) {
            try cleanupOwnedBackup()
        }
        return status
    }

    public func status() throws -> CursorMCPConnectionStatus {
        let configReady = try configuredAskKeyMatches()
        let helperReady = isExecutableRegularFile(helperURL) && signing.isTrusted(helperURL)
        let protocolReady = configReady && probeMCP()
        let brokerHealthy = probeBroker()
        let status = CursorMCPConnectionStatus(
            connected: configReady && helperReady && protocolReady && brokerHealthy,
            configReady: configReady,
            helperReady: helperReady,
            protocolReady: protocolReady,
            brokerHealthy: brokerHealthy
        )
        return status
    }


    public func rollback() throws {
        try withBackupLock { try rollbackLocked() }
    }

    private func rollbackLocked() throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            let backup = try readBackup()
            guard backupOwnership.matches(backup.generationID) else {
                throw CursorMCPError.rollbackFailed
            }
            try restore(backup)
            try FileManager.default.removeItem(at: backupURL)
        } catch {
            throw CursorMCPError.rollbackFailed
        }
    }

    private func loadExistingObject() throws -> [String: Any]? {
        let info = try inspect(userConfigURL)
        if !info.exists { return nil }
        let bytes = try readRegularFile(userConfigURL)
        return bytes.isEmpty ? [:] : try decodeObject(bytes)
    }

    private func mergeAskKey(into root: [String: Any]) -> [String: Any] {
        var root = root
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["askkey"] = [
            "command": helperURL.path,
            "args": ["mcp"],
        ]
        root["mcpServers"] = servers
        return root
    }

    private func makeDiff(existing: [String: Any]?, merged: [String: Any]) throws -> CursorMCPDiff {
        let before: String
        if let existing {
            before = String(decoding: try encode(redacted(existing)), as: UTF8.self)
        } else {
            before = ""
        }
        let after = String(decoding: try encode(redacted(merged)), as: UTF8.self)
        return CursorMCPDiff(before: before, after: after)
    }

    private func configuredAskKeyMatches() throws -> Bool {
        let object = try loadExistingObject()
        guard let servers = object?["mcpServers"] as? [String: Any],
              let askkey = servers["askkey"] as? [String: Any],
              askkey["command"] as? String == helperURL.path,
              stringArray(askkey["args"]) == ["mcp"] else {
            return false
        }
        return true
    }

    private func readBack(expectedMode: mode_t) throws {
        let info = try inspect(userConfigURL)
        guard info.exists, info.permissions == expectedMode else {
            throw CursorMCPError.readbackFailed
        }
        guard try configuredAskKeyMatches() else {
            throw CursorMCPError.readbackFailed
        }
    }

    private func prepareBackup(
        originalExisted: Bool,
        originalPermissions: mode_t,
        originalBytes: Data,
        replacementBytes: Data
    ) throws -> CursorRollbackBackup {
        let existingBackup = FileManager.default.fileExists(atPath: backupURL.path)
            ? try readBackup()
            : nil
        let currentDigest = Data(SHA256.hash(data: originalBytes))
        let currentPermissions = UInt16(originalPermissions)
        var backup = if let existingBackup,
                        (currentDigest == existingBackup.replacementDigest
                            && currentPermissions == (existingBackup.originalExisted
                                ? existingBackup.originalPermissions : 0o600))
                            || (existingBackup.originalExisted
                                && originalBytes == existingBackup.originalBytes
                                && currentPermissions == existingBackup.originalPermissions) {
            existingBackup
        } else {
            CursorRollbackBackup(
                generationID: UUID(),
                originalExisted: originalExisted,
                originalPermissions: UInt16(originalPermissions),
                originalBytes: originalBytes,
                replacementDigest: Data()
            )
        }
        backup.replacementDigest = Data(SHA256.hash(data: replacementBytes))
        try writeBackup(backup)
        backupOwnership.set(backup.generationID)
        return backup
    }

    private func writeBackup(_ backup: CursorRollbackBackup) throws {
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: backupDirectory.path
        )
        try JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
    }

    private func readBackup(at url: URL? = nil) throws -> CursorRollbackBackup {
        do {
            return try JSONDecoder().decode(
                CursorRollbackBackup.self,
                from: readRegularFile(url ?? backupURL)
            )
        } catch {
            throw CursorMCPError.rollbackFailed
        }
    }

    private func cleanupOwnedBackup() throws {
        let quarantine = backupDirectory
            .appendingPathComponent(".cursor-backup-cleanup-\(UUID().uuidString)")
        do {
            try Self.renameExclusively(from: backupURL, to: quarantine)
            let backup = try readBackup(at: quarantine)
            guard backupOwnership.matches(backup.generationID) else {
                throw CursorMCPError.backupCleanupFailed
            }
            let current = try inspect(userConfigURL)
            guard current.exists,
                  current.permissions == mode_t(backup.originalExisted
                    ? backup.originalPermissions : 0o600),
                  Data(SHA256.hash(data: try readRegularFile(userConfigURL)))
                    == backup.replacementDigest else {
                throw CursorMCPError.backupCleanupFailed
            }
            try removeBackupItem(quarantine)
            guard !FileManager.default.fileExists(atPath: quarantine.path) else {
                throw CursorMCPError.backupCleanupFailed
            }
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: backupURL.path) {
                try Self.renameExclusively(from: quarantine, to: backupURL)
            }
            throw CursorMCPError.backupCleanupFailed
        }
    }

    private func restore(_ backup: CursorRollbackBackup) throws {
        let current = try inspect(userConfigURL)
        if backup.originalExisted {
            try restoreOriginalConfig(backup, currentExists: current.exists)
        } else if current.exists {
            try removeAppliedConfig(backup)
        }
    }

    private func restoreOriginalConfig(
        _ backup: CursorRollbackBackup,
        currentExists: Bool
    ) throws {
        guard currentExists else {
            throw CursorMCPError.rollbackFailed
        }
        let quarantine = try quarantineCurrentConfig()
        let bytes: Data
        do {
            bytes = try readRegularFile(quarantine)
        } catch {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw CursorMCPError.rollbackFailed
        }
        guard bytes == backup.originalBytes
                || Data(SHA256.hash(data: bytes)) == backup.replacementDigest else {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw CursorMCPError.rollbackFailed
        }
        do {
            try writeAtomically(
                bytes: backup.originalBytes,
                mode: mode_t(backup.originalPermissions),
                replace: moveConfigExclusively
            )
            try removeConfig(quarantine)
            guard !FileManager.default.fileExists(atPath: quarantine.path) else {
                throw CursorMCPError.rollbackFailed
            }
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: userConfigURL.path) {
                try moveConfigExclusively(quarantine, userConfigURL)
            }
            throw CursorMCPError.rollbackFailed
        }
    }

    private func removeAppliedConfig(_ backup: CursorRollbackBackup) throws {
        let quarantine = try quarantineCurrentConfig()
        let bytes: Data
        do {
            bytes = try readRegularFile(quarantine)
        } catch {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw CursorMCPError.rollbackFailed
        }
        guard Data(SHA256.hash(data: bytes)) == backup.replacementDigest else {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw CursorMCPError.rollbackFailed
        }
        do {
            try removeConfig(quarantine)
            guard !FileManager.default.fileExists(atPath: quarantine.path) else {
                throw CursorMCPError.rollbackFailed
            }
        } catch {
            try moveConfigExclusively(quarantine, userConfigURL)
            throw CursorMCPError.rollbackFailed
        }
    }

    private func quarantineCurrentConfig() throws -> URL {
        let quarantine = userConfigURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-rollback-\(UUID().uuidString)")
        try moveConfigExclusively(userConfigURL, quarantine)
        return quarantine
    }

    private func writeAtomically(bytes: Data, mode: mode_t, replace: (URL, URL) throws -> Void) throws {
        let directory = userConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp: URL
        do {
            temp = try ClientConfigFileIO.writeExclusiveTemporary(
                bytes,
                in: directory,
                prefix: ".askkey-mcp-"
            )
        } catch {
            throw CursorMCPError.replaceFailed
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.setAttributes(
            [.posixPermissions: Int(mode)],
            ofItemAtPath: temp.path
        )
        try replace(temp, userConfigURL)
        let info = try inspect(userConfigURL)
        if !info.exists || info.permissions != mode {
            throw CursorMCPError.readbackFailed
        }
    }

    private func probeMCP() -> Bool {
        guard isExecutableRegularFile(helperURL), signing.isTrusted(helperURL) else { return false }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = ["mcp"]
        var environment = ProcessInfo.processInfo.environment
        environment["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            RuntimeOperationEvents.publish(.cursorHelper)
        } catch {
            return false
        }
        defer { stop(process) }
        do {
            try input.fileHandleForWriting.write(contentsOf: MCPHelperContract.requestPayload(.cursorClient))
            try input.fileHandleForWriting.close()
        } catch {
            return false
        }
        wait(process, until: Date().addingTimeInterval(2))
        if process.isRunning { return false }
        process.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (try? MCPHelperContract.inspect(response, identity: .cursorClient)) != nil
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        wait(process, until: Date().addingTimeInterval(0.2))
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            wait(process, until: Date().addingTimeInterval(0.2))
        }
    }

    private func wait(_ process: Process, until deadline: Date) {
        while process.isRunning, Date() < deadline {
            if RestrictedProcessCancellation.current?() == true { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func probeBroker() -> Bool {
        do {
            let response = try BrokerSocketClient(socketPath: brokerSocketPath)
                .send(.init(version: BrokerProtocolVersion.current, method: "health"))
            guard case .success(.health(let health)) = response, health.status == "ok" else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func inspect(_ url: URL) throws -> (exists: Bool, permissions: mode_t) {
        var st = stat()
        let result = url.path.withCString { lstat($0, &st) }
        if result != 0 {
            guard errno == ENOENT else { throw CursorMCPError.unsafeFile }
            return (false, 0)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw CursorMCPError.unsafeFile }
        return (true, st.st_mode & 0o777)
    }

    private func readRegularFile(_ url: URL) throws -> Data {
        try readRegularFileSnapshot(url).bytes
    }

    private func readRegularFileSnapshot(
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

    private func decodeObject(_ data: Data) throws -> [String: Any] {
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

    private func encode(_ object: [String: Any]) throws -> Data {
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

    private func stringArray(_ value: Any?) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.count == array.count ? strings : nil
    }

    private func isExecutableRegularFile(_ url: URL) -> Bool {
        var st = stat()
        guard url.path.withCString({ lstat($0, &st) }) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isExecutableFile(atPath: url.path) else {
            return false
        }
        return true
    }

    private static func renameExclusively(from source: URL, to destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw CursorMCPError.rollbackFailed
        }
    }

    private func withBackupLock<T>(_ body: () throws -> T) throws -> T {
        Self.processBackupLock.lock()
        defer { Self.processBackupLock.unlock() }
        let directory = backupLockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = backupLockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw CursorMCPError.rollbackFailed }
        defer { Darwin.close(descriptor) }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw CursorMCPError.rollbackFailed
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        return try body()
    }
}
