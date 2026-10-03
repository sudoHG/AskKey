import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker
import CryptoKit

extension GrokCLIAdapter {
    public func connect() throws -> GrokCLIConnectResult {
        try prepareIsolatedHome()
        try inspectConfigFile()
        let original = try readOriginal()
        if let text = original.text {
            try validateUserTOML(text)
        }
        try writeBackup(original)
        let result: GrokCLIConnectResult
        var appliedDigest: Data?
        do {
            try applyStdioConfig(
                originalText: original.text,
                appliedDigest: &appliedDigest
            )
            let verified = try verify(before: original.text ?? "")
            guard verified.connected else {
                throw GrokCLIAdapterError.verificationFailed(verified.reason)
            }
            result = verified
        } catch {
            if appliedDigest != nil {
                try beforeRollback()
                try restoreBackup(original, expectedDigest: appliedDigest)
            } else {
                try clearBackup()
            }
            if error is GrokCLIAdapterError { throw error }
            throw GrokCLIAdapterError.verificationFailed(error.localizedDescription)
        }
        try clearBackup()
        return result
    }

    private var backupDataURL: URL { backupDirectory.appendingPathComponent("grok-cli.config.toml") }

    private var backupStateURL: URL { backupDirectory.appendingPathComponent("grok-cli.state") }

    private func writeBackup(_ original: OriginalConfig) throws {
        try FileManager.default.createDirectory(
            at: backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backupDirectory.path)
        if let data = original.data, let mode = original.mode {
            try data.write(to: backupDataURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupDataURL.path)
            try Data("mode=\(mode)".utf8).write(to: backupStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupStateURL.path)
        } else {
            try? FileManager.default.removeItem(at: backupDataURL)
            try Data("missing".utf8).write(to: backupStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupStateURL.path)
        }
    }

    private func clearBackup() throws {
        do {
            if FileManager.default.fileExists(atPath: backupDataURL.path) {
                try removeBackupItem(backupDataURL)
            }
            if FileManager.default.fileExists(atPath: backupStateURL.path) {
                try removeBackupItem(backupStateURL)
            }
        } catch {
            throw GrokCLIAdapterError.backupCleanupFailed
        }
    }

    private func restoreBackup(_ original: OriginalConfig, expectedDigest: Data? = nil) throws {
        do {
            if let expectedDigest {
                let quarantine = configURL.deletingLastPathComponent()
                    .appendingPathComponent(".askkey-rollback-\(UUID().uuidString)")
                try renameExclusively(configURL, quarantine)
                guard Data(SHA256.hash(data: try Data(contentsOf: quarantine))) == expectedDigest else {
                    try renameExclusively(quarantine, configURL)
                    throw GrokCLIAdapterError.rollbackFailed
                }
                do {
                    if let data = original.data, let mode = original.mode {
                        try atomicWrite(data, to: configURL, mode: mode, exclusive: true)
                    }
                    try FileManager.default.removeItem(at: quarantine)
                } catch {
                    if FileManager.default.fileExists(atPath: quarantine.path),
                       !FileManager.default.fileExists(atPath: configURL.path) {
                        try renameExclusively(quarantine, configURL)
                    }
                    throw GrokCLIAdapterError.rollbackFailed
                }
            } else if let data = original.data, let mode = original.mode {
                try atomicWrite(data, to: configURL, mode: mode)
            } else if FileManager.default.fileExists(atPath: configURL.path) {
                try FileManager.default.removeItem(at: configURL)
            }
            try clearBackup()
        } catch {
            throw GrokCLIAdapterError.rollbackFailed
        }
    }

    private func applyStdioConfig(originalText: String?, appliedDigest: inout Data?) throws {
        if officialGrokIsUnsupported() {
            throw GrokCLIAdapterError.unsupportedClient
        }
        try FileManager.default.createDirectory(
            at: grokHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let preservedMode = try readOriginal().mode ?? 0o600
        if canUseOfficialGrok() {
            try runOfficialCLIInIsolation(originalText: originalText)
        }
        try afterOfficialPreflight()
        try writeLosslessStdio(
            originalText: originalText,
            mode: preservedMode,
            appliedDigest: &appliedDigest
        )
        try readBackStdio()
    }

    private func officialGrokIsUnsupported() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: grokExecutable.path) else { return false }
        guard let help = try? runGrok(["mcp", "add", "--help"]), help.status == 0 else { return false }
        let output = String(decoding: help.stdout + help.stderr, as: UTF8.self)
        return !output.contains("--scope")
    }

    private func runOfficialCLIInIsolation(originalText: String?) throws {
        let home = backupDirectory
            .appendingPathComponent("official-grok-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent("config.toml")
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let originalText {
                try Data(originalText.utf8).write(to: config, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: config.path
                )
            }
            var isolated = self
            isolated.grokHome = home
            do { try isolated.addWithOfficialCLI() }
            catch { NSLog("AskKey: Grok official MCP add preflight failed; using lossless TOML fallback: \(error.localizedDescription)") }
            try FileManager.default.removeItem(at: home)
        } catch {
            if FileManager.default.fileExists(atPath: home.path) {
                do { try FileManager.default.removeItem(at: home) }
                catch { throw GrokCLIAdapterError.rollbackFailed }
            }
            throw error
        }
    }

    private func addWithOfficialCLI() throws {
        var arguments = ["mcp", "add", "--scope", "user"]
        for (key, value) in helperEnvironment.sorted(by: { $0.key < $1.key }) {
            arguments.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        arguments.append(contentsOf: [serverName, "--", helperExecutable.path, "mcp"])
        let result = try runGrok(arguments)
        if result.status != 0 {
            throw GrokCLIAdapterError.verificationFailed("official_add")
        }
    }

    private func writeLosslessStdio(
        originalText: String?,
        mode: Int16,
        appliedDigest: inout Data?
    ) throws {
        let next = try GrokUserTOML.upsertStdio(
            in: originalText ?? "",
            serverName: serverName,
            command: helperExecutable.path,
            args: ["mcp"],
            env: helperEnvironment
        )
        let replacement = Data(next.utf8)
        appliedDigest = Data(SHA256.hash(data: replacement))
        try replaceIfUnchanged(
            originalText: originalText,
            replacement: replacement,
            mode: mode
        )
        try afterReplacementWrite()
    }

    private func replaceIfUnchanged(
        originalText: String?,
        replacement: Data,
        mode: Int16
    ) throws {
        guard let originalText else {
            try atomicWrite(replacement, to: configURL, mode: mode, exclusive: true)
            return
        }
        let quarantine = configURL.deletingLastPathComponent()
            .appendingPathComponent(".askkey-input-\(UUID().uuidString)")
        try renameExclusively(configURL, quarantine)
        let currentMode = try FileManager.default.attributesOfItem(atPath: quarantine.path)[.posixPermissions] as? NSNumber
        guard try Data(contentsOf: quarantine) == Data(originalText.utf8),
              currentMode?.int16Value == mode else {
            try renameExclusively(quarantine, configURL)
            throw GrokCLIAdapterError.rollbackFailed
        }
        do {
            try atomicWrite(replacement, to: configURL, mode: mode, exclusive: true)
            try FileManager.default.removeItem(at: quarantine)
        } catch {
            if FileManager.default.fileExists(atPath: quarantine.path),
               !FileManager.default.fileExists(atPath: configURL.path) {
                try renameExclusively(quarantine, configURL)
            }
            throw GrokCLIAdapterError.rollbackFailed
        }
    }

    private func readBackStdio() throws {
        try inspectConfigFile()
        let text = try String(contentsOf: configURL, encoding: .utf8)
        guard GrokUserTOML.askKeyTransport(in: text) == .stdio(command: helperExecutable.path, args: ["mcp"]) else {
            throw GrokCLIAdapterError.verificationFailed("readback")
        }
    }

    private func renameExclusively(_ source: URL, _ destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw GrokCLIAdapterError.rollbackFailed
        }
    }
}
