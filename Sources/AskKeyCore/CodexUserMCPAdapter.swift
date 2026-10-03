import Darwin
import CryptoKit
import Foundation
import AskKeyBroker
import Security

public enum CodexUserMCP {
    public static let serverName = "askkey"
    public static let bundledHelperPath = OfficialInstallTopology.canonicalHelperPath
    public static let helperVersion = "0.1.0"

    public static func userConfigURL(home: URL) -> URL {
        home.appendingPathComponent(".codex/config.toml")
    }

    public static func managedBackupDirectory(applicationSupport: URL) -> URL {
        applicationSupport
            .appendingPathComponent("client-backups", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
    }

    // Only minor lines whose stable `mcp add/get --json` contract was verified here.
    public static func allowsOfficialCLI(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return false
        }
        let parts = components.compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return parts[0] == 0 && ((42...50).contains(parts[1]) || [151, 153, 154, 156].contains(parts[1]))
    }
}

public enum CodexUserMCPError: Error, Equatable, LocalizedError {
    case unsafeConfigFile
    case illegalConfig
    case unknownCodexVersion
    case connectionFailed(String)
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeConfigFile:
            return "The Codex config file is not a safe regular file."
        case .illegalConfig:
            return "The Codex config file is not valid TOML."
        case .unknownCodexVersion:
            return "The Codex version is unknown and cannot be configured."
        case .connectionFailed(let reason):
            return "Ask Key could not verify the Codex connection (\(reason))."
        case .rollbackFailed:
            return "Ask Key could not restore the original Codex config. The managed backup was kept for recovery."
        }
    }
}

public enum CodexMCPCLIStatus: Equatable, Sendable {
    case missing
    case supported(version: String)
    case unknown(version: String?)
}

public struct CodexMCPCommand: Sendable {
    public var status: @Sendable () -> CodexMCPCLIStatus
    public var addAskKey: @Sendable (URL, URL) throws -> Void

    public init(
        status: @escaping @Sendable () -> CodexMCPCLIStatus,
        addAskKey: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.status = status
        self.addAskKey = addAskKey
    }

    public static let missing = CodexMCPCommand(status: { .missing }, addAskKey: { _, _ in })
}

public enum ProcessCodexMCPCommand {
    public static func make(executable: URL) -> CodexMCPCommand {
        CodexMCPCommand(
            status: {
                guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                    return .missing
                }
                guard let versionOutput = try? runProcess(
                    executable: executable,
                    arguments: ["--version"],
                    environment: ProcessInfo.processInfo.environment
                ) else {
                    return .unknown(version: nil)
                }
                let version = codexVersion(in: versionOutput)
                guard let version, CodexUserMCP.allowsOfficialCLI(version) else {
                    return .unknown(
                        version: version ?? versionOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                }
                guard (try? runProcess(
                    executable: executable,
                    arguments: ["mcp", "add", "--help"],
                    environment: ProcessInfo.processInfo.environment
                )) != nil else {
                    return .unknown(version: version)
                }
                return .supported(version: version)
            },
            addAskKey: { helper, config in
                let codexHome = config.deletingLastPathComponent()
                var environment = ProcessInfo.processInfo.environment
                environment["CODEX_HOME"] = codexHome.path
                environment["HOME"] = codexHome.deletingLastPathComponent().path
                _ = try runProcess(
                    executable: executable,
                    arguments: ["mcp", "add", CodexUserMCP.serverName, "--", helper.path, "mcp"],
                    environment: environment
                )
            }
        )
    }
}

public struct CodexHelperSigning: Sendable {
    public var isTrusted: @Sendable (URL) -> Bool

    public init(_ isTrusted: @escaping @Sendable (URL) -> Bool) {
        self.isTrusted = isTrusted
    }

    public static let executable = CodexHelperSigning { url in
        guard FileManager.default.isExecutableFile(atPath: url.path), !isSymlink(url) else {
            return false
        }
        guard let host = Bundle.main.executableURL else { return false }
        return HelperCodeSignatureTrust.matchesHost(helper: url, host: host)
    }

    public static let development = CodexHelperSigning { url in
        FileManager.default.isExecutableFile(atPath: url.path) && !isSymlink(url)
    }
}

public enum HelperCodeSignatureTrust {
    public static func matchesHost(helper: URL, host: URL) -> Bool {
        guard host.isFileURL, helper.isFileURL,
              host == host.standardizedFileURL,
              helper == helper.standardizedFileURL else { return false }
        let bundleURL = host.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        // Only the real host bundle's fixed helper is eligible, never PATH or aliases.
        guard host == host.resolvingSymlinksInPath(),
              helper == helper.resolvingSymlinksInPath(),
              bundleURL.pathExtension == "app",
              host.deletingLastPathComponent() == bundleURL.appendingPathComponent("Contents/MacOS"),
              helper == bundleURL.appendingPathComponent("Contents/Helpers/askkey"),
              Bundle(url: bundleURL)?.executableURL?.standardizedFileURL == host,
              (try? helper.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: helper.path),
              let hostInfo = validSigningInformation(at: bundleURL),
              let helperInfo = validSigningInformation(at: helper) else { return false }
        let hostTeam = hostInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let helperTeam = helperInfo[kSecCodeInfoTeamIdentifier as String] as? String
        if let hostTeam, !hostTeam.isEmpty {
            return helperTeam == hostTeam
        }
        // No Team ID is not itself trust. Both signatures must be explicitly ad-hoc,
        // and validating the entire host bundle above binds the helper to its seal.
        guard helperTeam == nil || helperTeam?.isEmpty == true,
              let hostFlags = hostInfo[kSecCodeInfoFlags as String] as? NSNumber,
              let helperFlags = helperInfo[kSecCodeInfoFlags as String] as? NSNumber else { return false }
        return hostFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
            && helperFlags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0
    }

    private static func validSigningInformation(at url: URL) -> [String: Any]? {
        var code: SecStaticCode?
        let validation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, validation, nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values
    }
}

public enum CodexConnectionStatus: Equatable, Sendable {
    case connected
    case notConnected
}

public struct CodexConfigDiff: Equatable, Sendable {
    public let before: String
    public let after: String

    public var redactedDescription: String {
        "--- before\n\(redactCodexTOML(before))\n+++ after\n\(redactCodexTOML(after))"
    }
}

public struct CodexApplyResult: Equatable, Sendable {
    public let status: CodexConnectionStatus
    public let diff: CodexConfigDiff
}

struct CodexApplyLifecycle {
    var afterBackup: () throws -> Void = {}
    var afterWrite: () throws -> Void = {}
    var beforeRestore: () throws -> Void = {}
}

struct CodexRollbackBackup: Codable {
    let originalExisted: Bool
    let originalText: String
    let originalMode: Int
    var replacementDigest: Data?

    var original: CodexOriginalConfig? {
        originalExisted ? CodexOriginalConfig(text: originalText, mode: originalMode) : nil
    }
}

public final class CodexUserMCPAdapter: @unchecked Sendable {
    public static let maximumConfigBytes = 1_048_576

    public let configURL: URL
    public let helperURL: URL
    public let backupDirectory: URL
    public let brokerSocketPath: String
    public let command: CodexMCPCommand
    public let signing: CodexHelperSigning
    public let requiresCredentialDiscovery: Bool
    var lifecycle = CodexApplyLifecycle()
    private let mutationLock = NSLock()

    public init(
        configURL: URL,
        helperURL: URL,
        backupDirectory: URL,
        brokerSocketPath: String,
        command: CodexMCPCommand = .missing,
        signing: CodexHelperSigning = .executable,
        requiresCredentialDiscovery: Bool = false
    ) {
        self.configURL = configURL
        self.helperURL = helperURL
        self.backupDirectory = backupDirectory
        self.brokerSocketPath = brokerSocketPath
        self.command = command
        self.signing = signing
        self.requiresCredentialDiscovery = requiresCredentialDiscovery
    }

    /// Reads configuration independently of CLI availability or connection health.
    public func hasConfiguration() throws -> Bool {
        try inspectConfigPath()
        return try CodexAskKeyTOML.hasServer(in: readConfig()?.text ?? "", named: "askkey")
    }

    public func preview() throws -> CodexConfigDiff {
        try assertKnownCLI()
        try inspectConfigPath()
        let original = try readConfig()?.text ?? ""
        let after = try CodexAskKeyTOML.upsert(
            original,
            command: helperURL.path,
            args: ["mcp"]
        )
        return CodexConfigDiff(before: original, after: after)
    }

    public func apply() throws -> CodexApplyResult {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try assertKnownCLI()
        try inspectConfigPath()
        try assertTrustedHelper()
        let original = try readConfig()
        let diff = try preview()
        try prepareBackup(original)
        var replacementDigest: Data?
        do {
            try lifecycle.afterBackup()
            let replacement = try writeDesired(original: original)
            replacementDigest = Data(SHA256.hash(data: replacement))
            try updateBackupReplacementDigest(replacementDigest)
            try lifecycle.afterWrite()
            try readBackAskKey()
            try verifyConnection()
            try removeBackupFile()
            return CodexApplyResult(status: .connected, diff: diff)
        } catch {
            let failure = error
            do {
                try lifecycle.beforeRestore()
                try restore(original, replacementDigest: replacementDigest)
                try removeBackupFile()
            } catch {
                throw CodexUserMCPError.rollbackFailed
            }
            if let typed = failure as? CodexUserMCPError {
                throw typed
            }
            throw CodexUserMCPError.connectionFailed("write")
        }
    }

    public func status() -> CodexConnectionStatus {
        do {
            try inspectConfigPath()
            try readBackAskKey()
            try verifyConnection()
            return .connected
        } catch {
            return .notConnected
        }
    }

    private func assertKnownCLI() throws {
        switch command.status() {
        case .missing:
            return
        case .unknown:
            throw CodexUserMCPError.unknownCodexVersion
        case .supported(let version):
            guard CodexUserMCP.allowsOfficialCLI(version) else {
                throw CodexUserMCPError.unknownCodexVersion
            }
        }
    }

    private func writeDesired(original: CodexOriginalConfig?) throws -> Data {
        let cli = command.status()
        if case .supported = cli {
            try runOfficialCLIInIsolation(original: original)
        }
        let next = try CodexAskKeyTOML.upsert(
            original?.text ?? "",
            command: helperURL.path,
            args: ["mcp"]
        )
        let bytes = Data(next.utf8)
        try replaceIfUnchanged(original: original, with: bytes)
        return bytes
    }

    private func runOfficialCLIInIsolation(original: CodexOriginalConfig?) throws {
        let directory = backupDirectory
            .appendingPathComponent("official-cli-\(UUID().uuidString)", isDirectory: true)
        let isolatedConfig = directory.appendingPathComponent("config.toml")
        do {
            try ensureDirectory(directory, mode: 0o700, excludeFromBackup: true)
            if let original {
                try Data(original.text.utf8).write(to: isolatedConfig, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: isolatedConfig.path
                )
            }
            try command.addAskKey(helperURL, isolatedConfig)
            try FileManager.default.removeItem(at: directory)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            } catch {
                throw CodexUserMCPError.rollbackFailed
            }
            throw error
        }
    }

    private func replaceIfUnchanged(
        original: CodexOriginalConfig?,
        with replacement: Data
    ) throws {
        guard let original else {
            try atomicWrite(replacement, mode: 0o600, exclusive: true)
            return
        }
        let quarantine = configURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-input-\(UUID().uuidString)")
        try renameExclusively(configURL, quarantine)
        let snapshot = try readRegularFile(quarantine)
        guard snapshot?.bytes == Data(original.text.utf8), snapshot?.mode == original.mode else {
            try renameExclusively(quarantine, configURL)
            throw CodexUserMCPError.rollbackFailed
        }
        do {
            try atomicWrite(replacement, mode: original.mode, exclusive: true)
            try FileManager.default.removeItem(at: quarantine)
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: configURL.path) {
                try renameExclusively(quarantine, configURL)
            }
            throw CodexUserMCPError.rollbackFailed
        }
    }

    private func readBackAskKey() throws {
        guard let current = try readConfig()?.text, hasExpectedAskKey(current) else {
            throw CodexUserMCPError.connectionFailed("config")
        }
    }

    private func hasExpectedAskKey(_ text: String) -> Bool {
        guard let entry = try? CodexAskKeyTOML.askKey(in: text) else { return false }
        return entry.enabled && entry.command == helperURL.path && entry.args == ["mcp"]
    }

    private func assertTrustedHelper() throws {
        if !signing.isTrusted(helperURL) || isSymlink(helperURL)
            || !FileManager.default.isExecutableFile(atPath: helperURL.path) {
            throw CodexUserMCPError.connectionFailed("helper")
        }
    }

    private func verifyConnection() throws {
        try assertTrustedHelper()
        do {
            let client = BrokerSocketClient(socketPath: brokerSocketPath)
            let health = try client.send(.init(version: BrokerProtocolVersion.current, method: "health"))
            guard case .success(.health(let payload)) = health, payload.status == "ok" else {
                throw CodexUserMCPError.connectionFailed("broker")
            }
            let version = try client.send(.init(version: BrokerProtocolVersion.current, method: "version"))
            guard case .success(.version(let payload)) = version,
                  payload.protocolVersion == BrokerProtocolVersion.current else {
                throw CodexUserMCPError.connectionFailed("version")
            }
        } catch let error as CodexUserMCPError {
            throw error
        } catch {
            throw CodexUserMCPError.connectionFailed("broker")
        }
        try verifyHelperMCP()
    }

    private func verifyHelperMCP() throws {
        var identity = MCPHelperContract.Identity.askKeyHelper
        if requiresCredentialDiscovery {
            identity.requiredTools.insert("credential_discovery_guard")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["ASKKEY_BROKER_SOCKET"] = brokerSocketPath
        let response: String
        do {
            response = try runProcess(
                executable: helperURL,
                arguments: ["mcp"],
                environment: environment,
                standardInput: try MCPHelperContract.requestPayload(identity)
            )
        } catch {
            throw CodexUserMCPError.connectionFailed("protocol")
        }
        do {
            _ = try MCPHelperContract.inspect(response, identity: identity)
        } catch {
            throw CodexUserMCPError.connectionFailed("protocol")
        }
    }

    private func inspectConfigPath() throws {
        try rejectUnsafeNode(configURL, allowMissing: true, requireRegularFile: true)
        try rejectUnsafeNode(configURL.deletingLastPathComponent(), allowMissing: true, requireRegularFile: false)
    }

    private func readConfig() throws -> CodexOriginalConfig? {
        try inspectConfigPath()
        guard let data = try readRegularFile(configURL) else { return nil }
        guard data.bytes.count <= Self.maximumConfigBytes else {
            throw CodexUserMCPError.illegalConfig
        }
        guard !data.bytes.contains(0) else { throw CodexUserMCPError.illegalConfig }
        guard let text = String(data: data.bytes, encoding: .utf8) else {
            throw CodexUserMCPError.illegalConfig
        }
        try CodexAskKeyTOML.validate(text)
        return CodexOriginalConfig(text: text, mode: data.mode)
    }

    private func prepareBackup(_ original: CodexOriginalConfig?) throws {
        try ensureDirectory(backupDirectory, mode: 0o700, excludeFromBackup: true)
        if FileManager.default.fileExists(atPath: backupFileURL.path) {
            let existing = try pendingBackup()
            if existing.replacementDigest == nil {
                guard backupMatchesOriginal(existing, current: original) else {
                    throw CodexUserMCPError.rollbackFailed
                }
                return
            }
            if backupMatchesCurrent(existing, current: original) {
                return
            }
        }
        try writeBackup(CodexRollbackBackup(
            originalExisted: original != nil,
            originalText: original?.text ?? "",
            originalMode: original?.mode ?? 0,
            replacementDigest: nil
        ))
    }

    private func backupMatchesCurrent(
        _ backup: CodexRollbackBackup,
        current: CodexOriginalConfig?
    ) -> Bool {
        if backupMatchesOriginal(backup, current: current) { return true }
        guard let current, let replacementDigest = backup.replacementDigest else {
            return !backup.originalExisted && current == nil
        }
        let expectedMode = backup.originalExisted ? backup.originalMode : 0o600
        return current.mode == expectedMode
            && Data(SHA256.hash(data: Data(current.text.utf8))) == replacementDigest
    }

    private func backupMatchesOriginal(
        _ backup: CodexRollbackBackup,
        current: CodexOriginalConfig?
    ) -> Bool {
        if !backup.originalExisted { return current == nil }
        return current?.text == backup.originalText && current?.mode == backup.originalMode
    }

    private func updateBackupReplacementDigest(_ digest: Data?) throws {
        guard FileManager.default.fileExists(atPath: backupFileURL.path) else { return }
        var backup = try pendingBackup()
        backup.replacementDigest = digest
        try writeBackup(backup)
    }

    private func writeBackup(_ backup: CodexRollbackBackup) throws {
        try JSONEncoder().encode(backup).write(to: backupFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: backupFileURL.path
        )
    }

    private func removeBackupFile() throws {
        if FileManager.default.fileExists(atPath: backupFileURL.path) {
            try FileManager.default.removeItem(at: backupFileURL)
        }
    }

    private func restore(_ original: CodexOriginalConfig?, replacementDigest: Data?) throws {
        let pending = try pendingBackup()
        let target = pending.original ?? original
        guard try readRegularFile(configURL) != nil else {
            if replacementDigest != nil { throw CodexUserMCPError.rollbackFailed }
            if let target {
                try atomicWrite(Data(target.text.utf8), mode: target.mode, exclusive: true)
            }
            return
        }
        let quarantine = configURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-rollback-\(UUID().uuidString)")
        try renameExclusively(configURL, quarantine)
        let quarantined = try readRegularFile(quarantine)
        guard let quarantined else { throw CodexUserMCPError.rollbackFailed }
        let targetBytes = target.map { Data($0.text.utf8) }
        guard quarantined.bytes == targetBytes
                || replacementDigest == Data(SHA256.hash(data: quarantined.bytes)) else {
            try renameExclusively(quarantine, configURL)
            throw CodexUserMCPError.rollbackFailed
        }
        do {
            if let target, let targetBytes {
                try atomicWrite(targetBytes, mode: target.mode, exclusive: true)
            }
            try FileManager.default.removeItem(at: quarantine)
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: configURL.path) {
                try renameExclusively(quarantine, configURL)
            }
            throw CodexUserMCPError.rollbackFailed
        }
    }

    private func pendingBackup() throws -> CodexRollbackBackup {
        guard let data = try readRegularFile(backupFileURL) else {
            throw CodexUserMCPError.rollbackFailed
        }
        do {
            return try JSONDecoder().decode(CodexRollbackBackup.self, from: data.bytes)
        } catch {
            throw CodexUserMCPError.rollbackFailed
        }
    }

    private var backupFileURL: URL {
        backupDirectory.appendingPathComponent("config.toml")
    }

    private func atomicWrite(_ data: Data, mode: Int, exclusive: Bool = false) throws {
        try ensureDirectory(configURL.deletingLastPathComponent(), mode: 0o700, excludeFromBackup: false)
        do {
            try ClientConfigFileIO.publishAtomically(
                data,
                to: configURL,
                mode: mode_t(mode),
                exclusive: exclusive,
                temporaryPrefix: ".askkey-"
            )
        } catch {
            throw CodexUserMCPError.connectionFailed("write")
        }
    }

    private func renameExclusively(_ source: URL, _ destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw CodexUserMCPError.rollbackFailed
        }
    }
}

struct CodexOriginalConfig: Equatable {
    let text: String
    let mode: Int
}

private struct FileBytes {
    let bytes: Data
    let mode: Int
}

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

    private struct Section {
        var raw: String
        var body: String
        var name: TableName?
        var isArray: Bool
        var newline: String
    }

    private struct TableName {
        var parts: [String]
        var isAskKey: Bool { parts.count >= 2 && parts[0] == "mcp_servers" && parts[1] == "askkey" }
        var isMCPServersRoot: Bool { parts == ["mcp_servers"] }
    }

    private enum Scan: Equatable {
        case normal
        case basicML(brackets: Int, braces: Int)
        case literalML(brackets: Int, braces: Int)
        case collections(brackets: Int, braces: Int)

        var isNormal: Bool {
            if case .normal = self { return true }
            return false
        }
    }

    private static func sections(in text: String) throws -> [Section] {
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

    private static func assertBalanced(_ text: String) throws {
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

    private static func assertAssignmentsAndKeyPaths(_ parts: [Section]) throws {
        var tables = Set<[String]>()
        var implicitTables = Set<[String]>()
        var values = Set<[String]>()
        var arrayTables = Set<[String]>()
        for part in parts {
            if let name = part.name {
                guard !name.parts.isEmpty, name.parts.allSatisfy({ !$0.isEmpty }) else {
                    throw CodexUserMCPError.illegalConfig
                }
                if part.isArray {
                    try defineArrayTable(
                        name.parts,
                        arrayTables: &arrayTables,
                        tables: tables,
                        values: values,
                        implicitTables: &implicitTables
                    )
                } else if arrayAncestor(name.parts, in: arrayTables) == nil {
                    try defineTable(
                        name.parts,
                        tables: &tables,
                        values: values,
                        arrayTables: arrayTables,
                        implicitTables: &implicitTables
                    )
                }
            }
            var keysInSection = Set<[String]>()
            var scan = Scan.normal
            for line in lines(of: part.raw, newline: part.newline) {
                if scan.isNormal {
                    let code = codePortion(line).trimmingCharacters(in: .whitespaces)
                    if let key = keyName(code) {
                        guard let local = dottedParts(key),
                              !local.isEmpty,
                              local.allSatisfy({ !$0.isEmpty }) else {
                            throw CodexUserMCPError.illegalConfig
                        }
                        if !keysInSection.insert(local).inserted {
                            throw CodexUserMCPError.illegalConfig
                        }
                        try assertAssignmentHasValue(code)
                        var path = part.name?.parts ?? []
                        path.append(contentsOf: local)
                        let underArray = part.isArray
                            || arrayAncestor(part.name?.parts ?? [], in: arrayTables) != nil
                        if !underArray {
                            try defineValue(
                                path,
                                tableDepth: part.name?.parts.count ?? 0,
                                tables: &tables,
                                values: &values,
                                arrayTables: arrayTables,
                                implicitTables: &implicitTables
                            )
                        }
                    }
                }
                scan = advance(scan, through: line)
            }
        }
    }

    private static func assertAssignmentHasValue(_ code: String) throws {
        guard let eq = code.firstIndex(of: "=") else { return }
        let value = code[code.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.isEmpty { throw CodexUserMCPError.illegalConfig }
    }

    private static func defineArrayTable(
        _ path: [String],
        arrayTables: inout Set<[String]>,
        tables: Set<[String]>,
        values: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if values.contains(path) || tables.contains(path) || implicitTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        if !arrayTables.insert(path).inserted { return }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) { throw CodexUserMCPError.illegalConfig }
            if tables.contains(prefix) || arrayTables.contains(prefix) { continue }
            implicitTables.insert(prefix)
        }
    }

    private static func defineTable(
        _ path: [String],
        tables: inout Set<[String]>,
        values: Set<[String]>,
        arrayTables: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if values.contains(path) || arrayTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        if tables.contains(path) { throw CodexUserMCPError.illegalConfig }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) || arrayTables.contains(prefix) {
                throw CodexUserMCPError.illegalConfig
            }
            if !tables.contains(prefix) { implicitTables.insert(prefix) }
        }
        implicitTables.remove(path)
        tables.insert(path)
    }

    private static func defineValue(
        _ path: [String],
        tableDepth: Int,
        tables: inout Set<[String]>,
        values: inout Set<[String]>,
        arrayTables: Set<[String]>,
        implicitTables: inout Set<[String]>
    ) throws {
        guard !path.isEmpty, path.allSatisfy({ !$0.isEmpty }) else {
            throw CodexUserMCPError.illegalConfig
        }
        if tables.contains(path) || values.contains(path) || arrayTables.contains(path) || implicitTables.contains(path) {
            throw CodexUserMCPError.illegalConfig
        }
        for index in 1..<path.count {
            let prefix = Array(path[0..<index])
            if values.contains(prefix) || arrayTables.contains(prefix) {
                throw CodexUserMCPError.illegalConfig
            }
            // Dotted keys define their parent tables, unlike table-header ancestors.
            if index > tableDepth {
                implicitTables.remove(prefix)
                tables.insert(prefix)
            }
        }
        values.insert(path)
    }

    private static func arrayAncestor(_ path: [String], in arrayTables: Set<[String]>) -> [String]? {
        var index = path.count - 1
        while index >= 1 {
            let prefix = Array(path[0..<index])
            if arrayTables.contains(prefix) { return prefix }
            index -= 1
        }
        return nil
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

    private static func stripAskKeyKeys(from raw: String, newline: String) throws -> String {
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

    private static func keyName(_ code: String) -> String? {
        guard let eq = code.firstIndex(of: "=") else { return nil }
        return String(code[..<eq]).trimmingCharacters(in: .whitespaces)
    }

    private static func dottedParts(_ text: String) -> [String]? {
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

    private static func scalarValue(_ code: String) throws -> String {
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

    private static func arrayValue(_ code: String) throws -> [String] {
        guard let eq = code.firstIndex(of: "=") else { throw CodexUserMCPError.illegalConfig }
        return try arrayLiteral(String(code[code.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
    }

    private static func arrayLiteral(_ raw: String) throws -> [String] {
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

    private static func inlineTable(_ code: String) -> [String: String]? {
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

    private static func lines(of text: String, newline: String) -> [String] {
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

    private static func codePortion(_ line: String) -> String {
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

    private static func advance(_ scan: Scan, through line: String) -> Scan {
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

    private static func braceDelta(_ text: String) -> Int {
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

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
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

private func rejectUnsafeNode(_ url: URL, allowMissing: Bool, requireRegularFile: Bool) throws {
    var st = stat()
    let result = url.path.withCString { lstat($0, &st) }
    if result != 0 {
        if allowMissing, errno == ENOENT { return }
        throw CodexUserMCPError.unsafeConfigFile
    }
    let type = st.st_mode & S_IFMT
    if type == S_IFLNK { throw CodexUserMCPError.unsafeConfigFile }
    if requireRegularFile, type != S_IFREG { throw CodexUserMCPError.unsafeConfigFile }
    if !requireRegularFile, type != S_IFDIR { throw CodexUserMCPError.unsafeConfigFile }
}

private func isSymlink(_ url: URL) -> Bool {
    var st = stat()
    guard url.path.withCString({ lstat($0, &st) }) == 0 else { return false }
    return (st.st_mode & S_IFMT) == S_IFLNK
}

private func ensureDirectory(_ url: URL, mode: Int, excludeFromBackup: Bool) throws {
    var st = stat()
    if url.path.withCString({ lstat($0, &st) }) == 0 {
        if (st.st_mode & S_IFMT) != S_IFDIR { throw CodexUserMCPError.unsafeConfigFile }
        if excludeFromBackup {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: url.path
            )
            try excludeURLFromBackup(url)
        }
        return
    }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: mode)],
        ofItemAtPath: url.path
    )
    if excludeFromBackup {
        try excludeURLFromBackup(url)
    }
}

private func excludeURLFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutable = url
    try mutable.setResourceValues(values)
}

private func readRegularFile(_ url: URL) throws -> FileBytes? {
    do {
        let file = try ClientConfigFileIO.readRegularFile(
            url,
            maximumBytes: CodexUserMCPAdapter.maximumConfigBytes
        )
        return FileBytes(bytes: file.bytes, mode: Int(file.mode))
    } catch ClientConfigFileIO.Failure.notFound {
        return nil
    } catch ClientConfigFileIO.Failure.tooLarge {
        throw CodexUserMCPError.illegalConfig
    } catch {
        throw CodexUserMCPError.unsafeConfigFile
    }
}

private func jsonObject(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

private func codexVersion(in text: String) -> String? {
    let tokens = text.split(whereSeparator: \.isWhitespace)
    // Keep the whole version token: stripping a suffix could authorize a prerelease.
    if tokens.count == 1 {
        return String(tokens[0])
    }
    guard tokens.count == 2, tokens[0] == "codex-cli" else { return nil }
    return String(tokens[1])
}

/// Codex policy on the shared restricted process: pre-write stdin, 4096-byte
/// input cap, monotonic 2s budget, stdout only, 1MiB overflow as failure,
/// immediate group kill. Format and error mapping stay here.
private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    standardInput: Data = Data()
) throws -> String {
    func failure() -> CodexUserMCPError { .connectionFailed("cli") }
    do {
        let result = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: executable,
                arguments: arguments,
                environment: environment,
                standardInput: standardInput,
                writeInputBeforeSpawn: true,
                maximumInputBytes: 4096,
                timeout: 2,
                usesMonotonicClock: true,
                captureStderr: false,
                maximumOutputBytes: 1_048_576,
                truncateOutput: false,
                terminationGrace: 0
            )
        )
        guard !result.timedOut, result.status == 0 else { throw failure() }
        return String(decoding: result.stdout, as: UTF8.self)
    } catch is RestrictedProcess.Failure {
        throw failure()
    }
}
