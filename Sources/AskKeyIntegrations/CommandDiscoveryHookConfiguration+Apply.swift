import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    public func apply(plan: CommandDiscoveryHookPlan) throws {
        lock.lock(); defer { lock.unlock() }
        try applyLocked(plan: plan)
    }

    func applyLocked(plan: CommandDiscoveryHookPlan, removingClaude: Bool = false) throws {
        guard plan.format == format else { throw Error.concurrentModification }
        let definition = try makeDefinition()
        let current = try readSnapshot(at: hooksURL, checkParent: true)
        if matches(current, bytes: plan.after, mode: plan.afterMode) { return }
        guard plan.changed, matches(current, bytes: plan.before, mode: plan.beforeMode) else {
            throw Error.concurrentModification
        }
        let reviewed = try removingClaude
            ? claudeRemovalPlan(snapshot: current, definition: definition)
            : makePlan(snapshot: current, definition: definition)
        guard reviewed == plan,
              let replacement = plan.after else {
            throw Error.concurrentModification
        }

        try prepareBackupDirectory()
        let backup = backupDirectory.appendingPathComponent(
            "command-discovery-\(UUID().uuidString).bak"
        )
        try writeBackup(plan.before ?? Data(), to: backup)

        do {
            try replace(
                expectedBytes: plan.before, expectedMode: plan.beforeMode,
                replacement: replacement, replacementMode: plan.afterMode
            )
            guard matches(
                try readSnapshot(at: hooksURL, checkParent: true),
                bytes: replacement, mode: plan.afterMode
            ) else { throw Error.writeFailed }
        } catch let error as CommandDiscoveryHookConfigurationError {
            switch error {
            case .concurrentModification, .unsafeHooksFile, .unsafeBackupDirectory,
                 .invalidHooksFile, .invalidExpectedHooks, .fileTooLarge,
                 .backupFailed, .ownedFileConflict, .customHookMismatch,
                 .multipleExpectedHooks:
                throw error
            default:
                try rollback(plan: plan, replacement: replacement)
                throw error
            }
        } catch {
            try rollback(plan: plan, replacement: replacement)
            throw Error.writeFailed
        }
    }

    private func prepareBackupDirectory() throws {
        try ensureDirectory(backupDirectory, error: .unsafeBackupDirectory)
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: backupDirectory.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var directory = backupDirectory
            try directory.setResourceValues(values)
        } catch { throw Error.unsafeBackupDirectory }
    }

    private func writeBackup(_ data: Data, to url: URL) throws {
        // Recheck immediately before resolving the destination path so a
        // directory replacement after preview cannot redirect the backup.
        try ensureDirectory(backupDirectory, error: .unsafeBackupDirectory)
        do {
            try ClientConfigFileIO.publishAtomically(
                data, to: url, mode: 0o600, exclusive: true,
                temporaryPrefix: ".askkey-command-backup-"
            )
        } catch { throw Error.backupFailed }
    }

    private func replace(
        expectedBytes: Data?, expectedMode: UInt32?, replacement: Data?, replacementMode: UInt32
    ) throws {
        let current = try readSnapshot(at: hooksURL, checkParent: true)
        guard matches(current, bytes: expectedBytes, mode: expectedMode) else {
            throw Error.concurrentModification
        }
        guard let current else {
            guard let replacement else { return }
            try ensureDirectory(hooksURL.deletingLastPathComponent(), error: .unsafeHooksFile)
            do {
                try ClientConfigFileIO.publishAtomically(
                    replacement, to: hooksURL, mode: mode_t(replacementMode), exclusive: true,
                    temporaryPrefix: ".askkey-command-"
                )
            } catch ClientConfigFileIO.Failure.exclusiveExists {
                throw Error.concurrentModification
            } catch { throw Error.writeFailed }
            return
        }

        if format == .claudeMerged, let replacement {
            try replaceClaude(current: current, replacement: replacement, mode: replacementMode)
            return
        }

        let quarantine = hooksURL.deletingLastPathComponent().appendingPathComponent(
            ".askkey-command-\(UUID().uuidString)"
        )
        do { try ClientConfigFileIO.renameExclusively(from: hooksURL, to: quarantine) }
        catch { throw Error.concurrentModification }
        do {
            guard let moved = try readSnapshot(at: quarantine, checkParent: false),
                  moved == current else {
                try restore(quarantine)
                throw Error.concurrentModification
            }
            if let replacement {
                do {
                    try ClientConfigFileIO.publishAtomically(
                        replacement, to: hooksURL, mode: mode_t(replacementMode), exclusive: true,
                        temporaryPrefix: ".askkey-command-"
                    )
                } catch {
                    try restore(quarantine)
                    throw Error.writeFailed
                }
            }
            try FileManager.default.removeItem(at: quarantine)
        } catch let error as Error { throw error }
        catch { throw Error.rollbackFailed }
    }

    private func restore(_ quarantine: URL) throws {
        guard !FileManager.default.fileExists(atPath: hooksURL.path) else { throw Error.rollbackFailed }
        do { try ClientConfigFileIO.renameExclusively(from: quarantine, to: hooksURL) }
        catch { throw Error.rollbackFailed }
    }

    private func rollback(plan: CommandDiscoveryHookPlan, replacement: Data) throws {
        let current = try readSnapshot(at: hooksURL, checkParent: true)
        if matches(current, bytes: plan.before, mode: plan.beforeMode) { return }
        guard matches(current, bytes: replacement, mode: plan.afterMode) else { throw Error.rollbackFailed }
        do {
            try replace(
                expectedBytes: replacement, expectedMode: plan.afterMode,
                replacement: plan.before, replacementMode: plan.beforeMode ?? 0o600
            )
        } catch { throw Error.rollbackFailed }
    }

    private func matches(_ snapshot: Snapshot?, bytes: Data?, mode: UInt32?) -> Bool {
        guard let bytes else { return snapshot == nil }
        return snapshot?.bytes == bytes && snapshot?.mode == mode
    }
}
