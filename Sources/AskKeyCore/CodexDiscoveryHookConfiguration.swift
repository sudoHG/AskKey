import Darwin
import Foundation

/// The reviewed, user-facing change to Codex's PreToolUse hook configuration.
///
/// `before` and `after` are retained for an optimistic-concurrency check. They
/// are opaque bytes to callers; `summary` is the only safe text intended for a
/// confirmation screen and describes Ask Key's hook only.
public struct CodexDiscoveryHookPlan: Equatable, Sendable {
    public let before: Data?
    public let after: Data?
    public let changed: Bool
    public let summary: String

    fileprivate let beforeMode: UInt32?
    fileprivate let afterMode: UInt32

    fileprivate init(
        before: Data?,
        after: Data?,
        changed: Bool,
        summary: String,
        beforeMode: UInt32?,
        afterMode: UInt32
    ) {
        self.before = before
        self.after = after
        self.changed = changed
        self.summary = summary
        self.beforeMode = beforeMode
        self.afterMode = afterMode
    }

    /// Safe text for a confirmation screen. It never includes other hooks.
    public var redactedDescription: String { summary }

    public static func == (
        lhs: CodexDiscoveryHookPlan,
        rhs: CodexDiscoveryHookPlan
    ) -> Bool {
        lhs.before == rhs.before
            && lhs.after == rhs.after
            && lhs.changed == rhs.changed
            && lhs.summary == rhs.summary
            && lhs.beforeMode == rhs.beforeMode
            && lhs.afterMode == rhs.afterMode
    }
}

public enum CodexDiscoveryHookConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case unsafeHooksFile
    case unsafeBackupDirectory
    case invalidHooksFile
    case fileTooLarge
    case multipleExpectedHooks
    case customHookMismatch
    case concurrentModification
    case backupFailed
    case writeFailed
    case rollbackFailed
    case restoreConflict

    public var errorDescription: String? {
        switch self {
        case .unsafeHooksFile:
            return "The Codex hooks file is not a safe regular file."
        case .unsafeBackupDirectory:
            return "The Ask Key Codex hook backup directory is not safe."
        case .invalidHooksFile:
            return "The Codex hooks file is not valid JSON hook configuration."
        case .fileTooLarge:
            return "The Codex hooks file is too large to inspect safely."
        case .multipleExpectedHooks:
            return "Multiple Ask Key discovery hooks were found."
        case .customHookMismatch:
            return "An existing Ask Key discovery hook has been customized."
        case .concurrentModification:
            return "The Codex hooks file changed after it was reviewed."
        case .backupFailed:
            return "The previous Codex hooks file could not be backed up safely."
        case .writeFailed:
            return "The Ask Key Codex discovery hook could not be written."
        case .rollbackFailed:
            return "The previous Codex hooks file could not be restored safely."
        case .restoreConflict:
            return "The Codex hooks file changed before restoration."
        }
    }
}

/// Previews and atomically manages Ask Key's Codex discovery hook.
///
/// This type owns only `hooks.json`. Codex trust state and `config.toml` are
/// managed by their respective integration boundaries.
public final class CodexDiscoveryHookConfiguration: @unchecked Sendable {
    public static let maximumHooksBytes = 1_048_576

    private static let expectedMatcher = "^(Bash|mcp__askkey__list_credentials)$"
    private static let expectedServer = "askkey"
    private static let expectedTool = "credential_discovery_guard"

    private let hooksURL: URL
    private let backupDirectory: URL
    private let mutationLock = NSLock()

    public init(hooksURL: URL, backupDirectory: URL) {
        self.hooksURL = hooksURL
        self.backupDirectory = backupDirectory
    }

    /// Returns a plan without writing either the hooks file or a backup.
    public func preview() throws -> CodexDiscoveryHookPlan {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        let snapshot = try readHooksSnapshot()
        let document = try parseDocument(snapshot?.bytes ?? Data())
        let matches = try matchingHookGroups(in: document)
        try validateOwnHook(matches)

        if let own = matches.first {
            let expected = Self.expectedHookGroup
            guard own.eventName == "PreToolUse",
                  jsonEqual(own.group, expected) else {
                throw CodexDiscoveryHookConfigurationError.customHookMismatch
            }
            return CodexDiscoveryHookPlan(
                before: snapshot?.bytes,
                after: snapshot?.bytes,
                changed: false,
                summary: "Ask Key's Codex discovery hook is already installed.",
                beforeMode: snapshot?.mode,
                afterMode: snapshot?.mode ?? 0o600
            )
        }

        var next = document
        try appendExpectedHook(to: &next)
        let after = try serializeDocument(next)
        let afterMode = snapshot?.mode ?? 0o600
        return CodexDiscoveryHookPlan(
            before: snapshot?.bytes,
            after: after,
            changed: true,
            summary: "Add Ask Key's Codex discovery hook.",
            beforeMode: snapshot?.mode,
            afterMode: afterMode
        )
    }

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

    public func hasExpectedHook() throws -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }

        guard let snapshot = try readHooksSnapshot() else { return false }
        let document = try parseDocument(snapshot.bytes)
        let matches = try matchingHookGroups(in: document)
        try validateOwnHook(matches)
        guard let own = matches.first else { return false }
        guard own.eventName == "PreToolUse", jsonEqual(own.group, Self.expectedHookGroup) else {
            throw CodexDiscoveryHookConfigurationError.customHookMismatch
        }
        return true
    }
}

private extension CodexDiscoveryHookConfiguration {
    struct HooksSnapshot {
        let bytes: Data
        let mode: UInt32
    }

    struct HookGroupMatch {
        let eventName: String
        let group: [String: Any]
    }

    var hooksParentURL: URL { hooksURL.deletingLastPathComponent() }

    static var expectedHookGroup: [String: Any] {
        [
            "matcher": expectedMatcher,
            "hooks": [[
                "type": "mcp_tool",
                "server": expectedServer,
                "tool": expectedTool,
                "input": [
                    "session_id": "${session_id}",
                    "turn_id": "${turn_id}",
                    "tool_name": "${tool_name}",
                    "tool_input": "${tool_input}"
                ],
                "timeout": 3
            ]]
        ]
    }

    func readHooksSnapshot() throws -> HooksSnapshot? {
        try inspectExistingDirectoryChain(hooksParentURL, error: .unsafeHooksFile)
        do {
            let file = try ClientConfigFileIO.readRegularFile(
                hooksURL,
                maximumBytes: Self.maximumHooksBytes
            )
            guard !file.bytes.contains(0) else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            return HooksSnapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw CodexDiscoveryHookConfigurationError.fileTooLarge
        } catch ClientConfigFileIO.Failure.unsafe {
            throw CodexDiscoveryHookConfigurationError.unsafeHooksFile
        }
    }

    func parseDocument(_ bytes: Data) throws -> [String: Any] {
        guard !bytes.isEmpty else { return [:] }
        do {
            let object = try JSONSerialization.jsonObject(with: bytes, options: [.fragmentsAllowed])
            guard let document = object as? [String: Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            return document
        } catch let error as CodexDiscoveryHookConfigurationError {
            throw error
        } catch {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }
    }

    func serializeDocument(_ document: [String: Any]) throws -> Data {
        do {
            var bytes = try JSONSerialization.data(
                withJSONObject: document,
                options: [.prettyPrinted, .sortedKeys]
            )
            bytes.append(0x0A)
            return bytes
        } catch {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }
    }

    func matchingHookGroups(in document: [String: Any]) throws -> [HookGroupMatch] {
        guard let rawHooks = document["hooks"] else { return [] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw CodexDiscoveryHookConfigurationError.invalidHooksFile
        }

        var matches: [HookGroupMatch] = []
        for (eventName, rawGroups) in hooks {
            guard let groups = rawGroups as? [Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            for rawGroup in groups {
                guard let group = rawGroup as? [String: Any],
                      let rawHooksInGroup = group["hooks"] as? [Any] else {
                    throw CodexDiscoveryHookConfigurationError.invalidHooksFile
                }
                for rawHook in rawHooksInGroup {
                    guard let hook = rawHook as? [String: Any] else {
                        throw CodexDiscoveryHookConfigurationError.invalidHooksFile
                    }
                    guard hook["server"] as? String == Self.expectedServer,
                          hook["tool"] as? String == Self.expectedTool else {
                        continue
                    }
                    matches.append(HookGroupMatch(eventName: eventName, group: group))
                }
            }
        }
        return matches
    }

    func validateOwnHook(_ matches: [HookGroupMatch]) throws {
        if matches.count > 1 {
            throw CodexDiscoveryHookConfigurationError.multipleExpectedHooks
        }
    }

    func appendExpectedHook(to document: inout [String: Any]) throws {
        var hooks: [String: Any]
        if let rawHooks = document["hooks"] {
            guard let existingHooks = rawHooks as? [String: Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            hooks = existingHooks
        } else {
            hooks = [:]
        }

        var preToolUse: [Any]
        if let rawPreToolUse = hooks["PreToolUse"] {
            guard let existing = rawPreToolUse as? [Any] else {
                throw CodexDiscoveryHookConfigurationError.invalidHooksFile
            }
            preToolUse = existing
        } else {
            preToolUse = []
        }
        preToolUse.append(Self.expectedHookGroup)
        hooks["PreToolUse"] = preToolUse
        document["hooks"] = hooks
    }

    func jsonEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else {
            return false
        }
        return left == right
    }

    func snapshotMatches(
        _ snapshot: HooksSnapshot?,
        bytes: Data?,
        mode: UInt32?
    ) -> Bool {
        guard let bytes else { return snapshot == nil }
        guard let snapshot else { return false }
        return snapshot.bytes == bytes && snapshot.mode == mode
    }

    func inspectExistingDirectoryChain(
        _ url: URL,
        error: CodexDiscoveryHookConfigurationError
    ) throws {
        try CodexHookDirectorySafety.inspect(url, error: error)
    }

    func ensureDirectoryChain(
        _ url: URL,
        error: CodexDiscoveryHookConfigurationError
    ) throws {
        try inspectExistingDirectoryChain(url, error: error)
        var missing: [URL] = []
        var current = url
        while true {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                break
            }
            let failure = errno
            guard failure == ENOENT else { throw error }
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { throw error }
            current = parent
        }

        for directory in missing.reversed() {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                var info = stat()
                let result = directory.path.withCString { lstat($0, &info) }
                guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw error
                }
            }
            var info = stat()
            guard directory.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw error
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: directory.path
                )
            } catch {
                throw error
            }
        }
    }

    func prepareBackupDirectory() throws {
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

    func writeBackup(_ bytes: Data, to url: URL) throws {
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

    func replaceFile(
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

    func readSnapshot(at url: URL) throws -> HooksSnapshot? {
        do {
            let file = try ClientConfigFileIO.readRegularFile(url, maximumBytes: Self.maximumHooksBytes)
            return HooksSnapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw CodexDiscoveryHookConfigurationError.fileTooLarge
        } catch {
            throw CodexDiscoveryHookConfigurationError.unsafeHooksFile
        }
    }

    func restoreQuarantine(_ quarantine: URL) throws {
        guard !FileManager.default.fileExists(atPath: hooksURL.path) else {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
        do {
            try ClientConfigFileIO.renameExclusively(from: quarantine, to: hooksURL)
        } catch {
            throw CodexDiscoveryHookConfigurationError.rollbackFailed
        }
    }

    func rollbackAfterFailedApply(
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

/// Checks every ancestor before Codex hook configuration or backup access.
/// Inspect the original spelling so a user symlink cannot disappear during
/// path normalization, even when its child directory already exists.
enum CodexHookDirectorySafety {
    static func inspect<Failure: Error>(_ url: URL, error: Failure) throws {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/") else { throw error }
        var prefixes = ["/"]
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + String(component)
            prefixes.append(prefix)
        }
        for current in prefixes {
            var info = stat()
            if current.withCString({ lstat($0, &info) }) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                } else {
                    guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                }
            } else {
                guard errno == ENOENT else { throw error }
            }
        }
    }

    /// Only macOS's root-owned /tmp and /var aliases are accepted. Never
    /// resolve the complete user path to decide whether a link is safe.
    private static func trustedSystemAlias(_ path: String, info: stat) -> Bool {
        let expectedLink: String
        let expectedTarget: String
        switch path {
        case "/tmp":
            expectedLink = "private/tmp"
            expectedTarget = "/private/tmp"
        case "/var":
            expectedLink = "private/var"
            expectedTarget = "/private/var"
        default:
            return false
        }
        guard info.st_uid == 0 else { return false }

        var linkBytes = [UInt8](repeating: 0, count: 1024)
        let linkLength = path.withCString { pathPointer in
            linkBytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.readlink(pathPointer, base.assumingMemoryBound(to: CChar.self), buffer.count)
            }
        }
        guard linkLength >= 0,
              String(decoding: linkBytes.prefix(linkLength), as: UTF8.self) == expectedLink else {
            return false
        }

        var targetInfo = stat()
        return expectedTarget.withCString({ lstat($0, &targetInfo) }) == 0
            && (targetInfo.st_mode & S_IFMT) == S_IFDIR
            && targetInfo.st_uid == 0
    }
}
