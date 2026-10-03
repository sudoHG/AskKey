import Darwin
import CryptoKit
import Foundation
import AskKeySystem
import AskKeyBroker
import Security

extension CodexUserMCPAdapter {
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
}
