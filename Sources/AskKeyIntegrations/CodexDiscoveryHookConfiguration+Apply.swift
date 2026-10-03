import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    /// Applies exactly the reviewed plan. A plan for an already-applied state
    /// is a safe no-op, which keeps repeated installation idempotent.
    public func apply(plan: CodexDiscoveryHookPlan) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        guard let after = plan.after else {
            throw CodexDiscoveryHookConfigurationError.writeFailed
        }
        let current = try readHooksSnapshot()

        if snapshotMatches(current, bytes: after, mode: plan.afterMode) {
            return
        }
        guard snapshotMatches(current, bytes: plan.before, mode: plan.beforeMode) else {
            throw CodexDiscoveryHookConfigurationError.concurrentModification
        }
        guard plan.changed else { return }

        try prepareBackupDirectory()
        let backupURL = backupDirectory.appendingPathComponent(
            "codex-discovery-\(UUID().uuidString).bak"
        )
        do {
            try writeBackup(plan.before ?? Data(), to: backupURL)
        } catch let error as CodexDiscoveryHookConfigurationError {
            throw error
        } catch {
            throw CodexDiscoveryHookConfigurationError.backupFailed
        }

        do {
            try replaceFile(
                expectedBytes: plan.before,
                expectedMode: plan.beforeMode,
                replacement: after,
                replacementMode: plan.afterMode
            )
            let written = try readHooksSnapshot()
            guard snapshotMatches(written, bytes: after, mode: plan.afterMode) else {
                throw CodexDiscoveryHookConfigurationError.writeFailed
            }
        } catch let error as CodexDiscoveryHookConfigurationError {
            switch error {
            case .concurrentModification, .unsafeHooksFile, .unsafeBackupDirectory,
                 .invalidHooksFile, .fileTooLarge, .backupFailed:
                throw error
            default:
                try rollbackAfterFailedApply(plan: plan, replacement: after)
                throw error
            }
        } catch {
            try rollbackAfterFailedApply(plan: plan, replacement: after)
            throw CodexDiscoveryHookConfigurationError.writeFailed
        }
    }

    /// Restores the reviewed `before` bytes only while the file still equals
    /// the reviewed `after` bytes and mode. A concurrent change is preserved.
    public func restore(plan: CodexDiscoveryHookPlan) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let current = try readHooksSnapshot()
        guard snapshotMatches(current, bytes: plan.after, mode: plan.afterMode) else {
            throw CodexDiscoveryHookConfigurationError.restoreConflict
        }
        guard plan.changed else { return }

        do {
            try replaceFile(
                expectedBytes: plan.after,
                expectedMode: plan.afterMode,
                replacement: plan.before,
                replacementMode: plan.beforeMode ?? 0o600
            )
        } catch let error as CodexDiscoveryHookConfigurationError {
            if error == .concurrentModification {
                throw CodexDiscoveryHookConfigurationError.restoreConflict
            }
            throw error
        } catch {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
    }

    private func snapshotMatches(
        _ snapshot: HooksSnapshot?,
        bytes: Data?,
        mode: UInt32?
    ) -> Bool {
        guard let bytes else { return snapshot == nil }
        guard let snapshot else { return false }
        return snapshot.bytes == bytes && snapshot.mode == mode
    }

    private func prepareBackupDirectory() throws {
        try ensureDirectoryChain(backupDirectory, error: .unsafeBackupDirectory)

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: backupDirectory.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = backupDirectory
            try directory.setResourceValues(values)
        } catch {
            throw CodexDiscoveryHookConfigurationError.unsafeBackupDirectory
        }
    }

    private func writeBackup(_ bytes: Data, to url: URL) throws {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw CodexDiscoveryHookConfigurationError.backupFailed
            }
            guard (try? ClientConfigFileIO.readRegularFile(url).bytes) == bytes else {
                throw CodexDiscoveryHookConfigurationError.backupFailed
            }
            return
        }
        guard errno == ENOENT else {
            throw CodexDiscoveryHookConfigurationError.backupFailed
        }
        do {
            try ClientConfigFileIO.publishAtomically(
                bytes,
                to: url,
                mode: 0o600,
                exclusive: true,
                temporaryPrefix: ".askkey-discovery-backup-"
            )
        } catch {
            throw CodexDiscoveryHookConfigurationError.backupFailed
        }
    }

    private func replaceFile(
        expectedBytes: Data?,
        expectedMode: UInt32?,
        replacement: Data?,
        replacementMode: UInt32
    ) throws {
        let current = try readHooksSnapshot()
        guard snapshotMatches(current, bytes: expectedBytes, mode: expectedMode) else {
            throw CodexDiscoveryHookConfigurationError.concurrentModification
        }

        guard let current else {
            guard let replacement else { return }
            try ensureDirectoryChain(hooksParentURL, error: .unsafeHooksFile)
            do {
                try ClientConfigFileIO.publishAtomically(
                    replacement,
                    to: hooksURL,
                    mode: mode_t(replacementMode),
                    exclusive: true,
                    temporaryPrefix: ".askkey-discovery-"
                )
            } catch ClientConfigFileIO.Failure.exclusiveExists {
                throw CodexDiscoveryHookConfigurationError.concurrentModification
            } catch {
                throw CodexDiscoveryHookConfigurationError.writeFailed
            }
            return
        }

        let quarantine = hooksParentURL.appendingPathComponent(
            ".askkey-discovery-\(UUID().uuidString)"
        )
        do {
            try ClientConfigFileIO.renameExclusively(from: hooksURL, to: quarantine)
        } catch {
            throw CodexDiscoveryHookConfigurationError.concurrentModification
        }

        do {
            guard let moved = try readSnapshot(at: quarantine),
                  moved.bytes == current.bytes,
                  moved.mode == current.mode else {
                try restoreQuarantine(quarantine)
                throw CodexDiscoveryHookConfigurationError.concurrentModification
            }

            if let replacement {
                do {
                    try ClientConfigFileIO.publishAtomically(
                        replacement,
                        to: hooksURL,
                        mode: mode_t(replacementMode),
                        exclusive: true,
                        temporaryPrefix: ".askkey-discovery-"
                    )
                } catch {
                    try restoreQuarantine(quarantine)
                    throw CodexDiscoveryHookConfigurationError.writeFailed
                }
            }
            try FileManager.default.removeItem(at: quarantine)
        } catch let error as CodexDiscoveryHookConfigurationError {
            throw error
        } catch {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
    }

    private func restoreQuarantine(_ quarantine: URL) throws {
        guard !FileManager.default.fileExists(atPath: hooksURL.path) else {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
        do {
            try ClientConfigFileIO.renameExclusively(from: quarantine, to: hooksURL)
        } catch {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
    }

    private func rollbackAfterFailedApply(
        plan: CodexDiscoveryHookPlan,
        replacement: Data
    ) throws {
        let current = try readHooksSnapshot()
        if snapshotMatches(current, bytes: plan.before, mode: plan.beforeMode) { return }
        guard snapshotMatches(current, bytes: replacement, mode: plan.afterMode) else {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
        do {
            try replaceFile(
                expectedBytes: replacement,
                expectedMode: plan.afterMode,
                replacement: plan.before,
                replacementMode: plan.beforeMode ?? 0o600
            )
        } catch {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
    }
}
