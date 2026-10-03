import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import AskKeySystem
import AskKeyBroker

extension CursorUserMCPAdapter {
    var backupURL: URL {
        backupDirectory.appendingPathComponent("cursor-mcp.json")
    }

    private var backupLockURL: URL {
        backupDirectory.deletingLastPathComponent().appendingPathComponent(".cursor.lock")
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

    func cleanupOwnedBackup() throws {
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

    static func renameExclusively(from source: URL, to destination: URL) throws {
        do {
            try ClientConfigFileIO.renameExclusively(from: source, to: destination)
        } catch {
            throw CursorMCPError.rollbackFailed
        }
    }

    func withBackupLock<T>(_ body: () throws -> T) throws -> T {
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
