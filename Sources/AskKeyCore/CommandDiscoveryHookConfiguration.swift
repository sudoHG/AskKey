import Darwin
import Foundation

public enum CommandDiscoveryHookFormat: String, Equatable, Sendable {
    case cursorMerged
    case grokOwned

    fileprivate var name: String {
        switch self {
        case .cursorMerged: return "Cursor"
        case .grokOwned: return "Grok"
        }
    }

    fileprivate var invocationMarker: String {
        switch self {
        case .cursorMerged: return "hook cursor"
        case .grokOwned: return "hook grok"
        }
    }
}

public struct CommandDiscoveryHookPlan: Equatable, Sendable {
    public let before: Data?
    public let after: Data?
    public let changed: Bool
    public let summary: String
    public let format: CommandDiscoveryHookFormat

    fileprivate let beforeMode: UInt32?
    fileprivate let afterMode: UInt32

    fileprivate init(
        before: Data?, after: Data?, changed: Bool, summary: String,
        format: CommandDiscoveryHookFormat, beforeMode: UInt32?, afterMode: UInt32
    ) {
        self.before = before
        self.after = after
        self.changed = changed
        self.summary = summary
        self.format = format
        self.beforeMode = beforeMode
        self.afterMode = afterMode
    }

    public var redactedDescription: String { summary }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.before == rhs.before && lhs.after == rhs.after && lhs.changed == rhs.changed
            && lhs.summary == rhs.summary && lhs.format == rhs.format
            && lhs.beforeMode == rhs.beforeMode && lhs.afterMode == rhs.afterMode
    }
}

public enum CommandDiscoveryHookConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case unsafeHooksFile
    case unsafeBackupDirectory
    case invalidHooksFile
    case invalidExpectedHooks
    case fileTooLarge
    case multipleExpectedHooks
    case customHookMismatch
    case ownedFileConflict
    case concurrentModification
    case backupFailed
    case writeFailed
    case rollbackFailed

    public var errorDescription: String? {
        switch self {
        case .unsafeHooksFile: return "The command-hook file is not safe."
        case .unsafeBackupDirectory: return "The command-hook backup directory is not safe."
        case .invalidHooksFile: return "The command-hook file is invalid."
        case .invalidExpectedHooks: return "The reviewed command-hook definition is invalid."
        case .fileTooLarge: return "The command-hook file is too large."
        case .multipleExpectedHooks: return "Multiple Ask Key command hooks were found."
        case .customHookMismatch: return "An Ask Key command hook has been customized."
        case .ownedFileConflict: return "The Grok command-hook file contains unknown settings."
        case .concurrentModification: return "The command-hook file changed after review."
        case .backupFailed: return "The command-hook backup failed."
        case .writeFailed: return "The command hook could not be written."
        case .rollbackFailed: return "The command-hook rollback failed."
        }
    }
}

/// Transactional command-hook configuration for Cursor and Grok.
///
/// The integration supplies `expectedHooks`, so this type does not guess a
/// client matcher or event. Cursor merges its expected event arrays; Grok's
/// dedicated file is owned by Ask Key and rejects unknown existing content.
public final class CommandDiscoveryHookConfiguration: @unchecked Sendable {
    public static let maximumHooksBytes = 1_048_576
    public typealias Format = CommandDiscoveryHookFormat

    private let hooksURL: URL
    private let backupDirectory: URL
    private let expectedHooks: Data
    private let format: CommandDiscoveryHookFormat
    private let lock = NSLock()

    public init(
        hooksURL: URL,
        backupDirectory: URL,
        expectedHooks: Data,
        format: CommandDiscoveryHookFormat
    ) {
        self.hooksURL = hooksURL.standardizedFileURL
        self.backupDirectory = backupDirectory.standardizedFileURL
        self.expectedHooks = expectedHooks
        self.format = format
    }

    public func preview() throws -> CommandDiscoveryHookPlan {
        lock.lock(); defer { lock.unlock() }
        let definition = try makeDefinition()
        return try makePlan(snapshot: try readSnapshot(at: hooksURL, checkParent: true), definition: definition)
    }

    public func apply(plan: CommandDiscoveryHookPlan) throws {
        lock.lock(); defer { lock.unlock() }
        guard plan.format == format else { throw Error.concurrentModification }
        let definition = try makeDefinition()
        let current = try readSnapshot(at: hooksURL, checkParent: true)
        if matches(current, bytes: plan.after, mode: plan.afterMode) { return }
        guard plan.changed, matches(current, bytes: plan.before, mode: plan.beforeMode) else {
            throw Error.concurrentModification
        }
        guard try makePlan(snapshot: current, definition: definition) == plan,
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

    public func hasExpectedHook() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        let definition = try makeDefinition()
        guard let snapshot = try readSnapshot(at: hooksURL, checkParent: true) else { return false }
        return try hasExpectedHook(in: snapshot.bytes, definition: definition)
    }
}

private extension CommandDiscoveryHookConfiguration {
    typealias Error = CommandDiscoveryHookConfigurationError

    struct Snapshot: Equatable {
        let bytes: Data
        let mode: UInt32
    }

    struct Definition {
        let root: [String: Any]
        let groups: [String: [[String: Any]]]
        let commands: [String]
        let canonical: Data
    }

    struct Match {
        let event: String
        let exact: Bool
        let ownLike: Bool
    }

    func makeDefinition() throws -> Definition {
        guard expectedHooks.count <= Self.maximumHooksBytes, !expectedHooks.contains(0) else {
            throw Error.invalidExpectedHooks
        }
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: expectedHooks, options: [.fragmentsAllowed]
            ) as? [String: Any] else { throw Error.invalidExpectedHooks }
            object = value
        } catch let error as Error { throw error }
        catch { throw Error.invalidExpectedHooks }

        switch format {
        case .grokOwned:
            let commands = allCommands(in: object)
            guard !commands.isEmpty else { throw Error.invalidExpectedHooks }
            return Definition(
                root: object, groups: [:], commands: commands,
                canonical: try serialize(object, error: .invalidExpectedHooks)
            )
        case .cursorMerged:
            guard let version = object["version"] as? NSNumber, version.intValue == 1,
                  let rawHooks = object["hooks"] as? [String: Any], !rawHooks.isEmpty else {
                throw Error.invalidExpectedHooks
            }
            var groups: [String: [[String: Any]]] = [:]
            var commands: [String] = []
            for event in rawHooks.keys.sorted() {
                guard let rawGroups = rawHooks[event] as? [Any], !rawGroups.isEmpty else {
                    throw Error.invalidExpectedHooks
                }
                var eventGroups: [[String: Any]] = []
                for rawGroup in rawGroups {
                    guard let group = rawGroup as? [String: Any], !commandStrings(in: group).isEmpty else {
                        throw Error.invalidExpectedHooks
                    }
                    eventGroups.append(group)
                    commands.append(contentsOf: commandStrings(in: group))
                }
                groups[event] = eventGroups
            }
            return Definition(
                root: object, groups: groups, commands: commands,
                canonical: try serialize(object, error: .invalidExpectedHooks)
            )
        }
    }

    func makePlan(snapshot: Snapshot?, definition: Definition) throws -> CommandDiscoveryHookPlan {
        switch format {
        case .grokOwned:
            if let snapshot {
                let existing = try object(snapshot.bytes, error: .invalidHooksFile)
                if jsonEqual(existing, definition.root) { return noChange(snapshot) }
                if containsOwnLike(in: existing, commands: definition.commands) {
                    throw Error.customHookMismatch
                }
                throw Error.ownedFileConflict
            }
            return CommandDiscoveryHookPlan(
                before: nil, after: definition.canonical, changed: true,
                summary: "Add Ask Key's Grok discovery command hook.", format: format,
                beforeMode: nil, afterMode: 0o600
            )

        case .cursorMerged:
            guard let snapshot else {
                return CommandDiscoveryHookPlan(
                    before: nil, after: definition.canonical, changed: true,
                    summary: "Add Ask Key's Cursor discovery command hooks.", format: format,
                    beforeMode: nil, afterMode: 0o600
                )
            }
            let existing = try object(snapshot.bytes, error: .invalidHooksFile)
            let found = try cursorMatches(in: existing, definition: definition)
            try validate(found, expected: definition.groups)
            let exactCount = found.filter(\.exact).count
            let expectedCount = definition.groups.values.reduce(0) { $0 + $1.count }
            if exactCount == expectedCount {
                return noChange(snapshot)
            }
            var merged = existing
            try append(to: &merged, definition: definition)
            return CommandDiscoveryHookPlan(
                before: snapshot.bytes, after: try serialize(merged, error: .invalidHooksFile), changed: true,
                summary: "Add Ask Key's Cursor discovery command hooks.", format: format,
                beforeMode: snapshot.mode, afterMode: snapshot.mode
            )
        }
    }

    func noChange(_ snapshot: Snapshot) -> CommandDiscoveryHookPlan {
        CommandDiscoveryHookPlan(
            before: snapshot.bytes, after: snapshot.bytes, changed: false,
            summary: "Ask Key's \(format.name) discovery command hook is already installed.",
            format: format, beforeMode: snapshot.mode, afterMode: snapshot.mode
        )
    }

    func hasExpectedHook(in bytes: Data, definition: Definition) throws -> Bool {
        let existing = try object(bytes, error: .invalidHooksFile)
        switch format {
        case .grokOwned:
            if jsonEqual(existing, definition.root) { return true }
            if containsOwnLike(in: existing, commands: definition.commands) {
                throw Error.customHookMismatch
            }
            throw Error.ownedFileConflict
        case .cursorMerged:
            let found = try cursorMatches(in: existing, definition: definition)
            try validate(found, expected: definition.groups)
            return found.filter(\.exact).count == definition.groups.values.reduce(0) { $0 + $1.count }
        }
    }

    func object(_ bytes: Data, error: Error) throws -> [String: Any] {
        guard !bytes.isEmpty, !bytes.contains(0) else { throw error }
        do {
            guard let value = try JSONSerialization.jsonObject(
                with: bytes, options: [.fragmentsAllowed]
            ) as? [String: Any] else { throw error }
            return value
        } catch let caught as Error { throw caught }
        catch { throw error }
    }

    func serialize(_ object: [String: Any], error: Error) throws -> Data {
        do {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A)
            return data
        } catch { throw error }
    }

    func jsonEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard let left = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let right = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]) else { return false }
        return left == right
    }

    func cursorMatches(in document: [String: Any], definition: Definition) throws -> [Match] {
        guard let version = document["version"] as? NSNumber, version.intValue == 1 else {
            throw Error.invalidHooksFile
        }
        let rawHooks: [String: Any]
        if let value = document["hooks"] {
            guard let hooks = value as? [String: Any] else { throw Error.invalidHooksFile }
            rawHooks = hooks
        } else {
            rawHooks = [:]
        }
        var found: [Match] = []
        for event in rawHooks.keys {
            guard let rawGroups = rawHooks[event] as? [Any] else { throw Error.invalidHooksFile }
            for rawGroup in rawGroups {
                guard let group = rawGroup as? [String: Any] else { throw Error.invalidHooksFile }
                let commands = commandStrings(in: group)
                guard !commands.isEmpty else { continue }
                let exact = definition.groups[event]?.contains { jsonEqual($0, group) } == true
                let ownLike = commands.contains { isOwnLike($0, expected: definition.commands) }
                if exact || ownLike {
                    found.append(Match(event: event, exact: exact, ownLike: ownLike))
                }
            }
        }
        return found
    }

    func validate(_ matches: [Match], expected: [String: [[String: Any]]]) throws {
        let own = matches.filter(\.ownLike).count
        let custom = matches.filter { $0.ownLike && !$0.exact }.count
        let expectedCount = expected.values.reduce(0) { $0 + $1.count }
        let exactByEvent = Dictionary(grouping: matches.filter(\.exact), by: \.event)
        if exactByEvent.contains(where: { $0.value.count > (expected[$0.key]?.count ?? 0) }) {
            throw Error.multipleExpectedHooks
        }
        if own > expectedCount { throw Error.multipleExpectedHooks }
        if custom > 0 { throw Error.customHookMismatch }
    }

    func append(to document: inout [String: Any], definition: Definition) throws {
        var hooks: [String: Any]
        if let raw = document["hooks"] {
            guard let existing = raw as? [String: Any] else { throw Error.invalidHooksFile }
            hooks = existing
        } else {
            hooks = [:]
        }
        for event in definition.groups.keys.sorted() {
            var groups = (hooks[event] as? [Any]) ?? []
            if hooks[event] != nil, hooks[event] as? [Any] == nil { throw Error.invalidHooksFile }
            for expected in definition.groups[event] ?? [] {
                if !groups.contains(where: { ($0 as? [String: Any]).map { jsonEqual($0, expected) } == true }) {
                    groups.append(expected)
                }
            }
            hooks[event] = groups
        }
        document["hooks"] = hooks
    }

    func commandStrings(in group: [String: Any]) -> [String] {
        var values: [String] = []
        if let command = group["command"] as? String, !command.isEmpty { values.append(command) }
        if let handlers = group["hooks"] as? [Any] {
            for handler in handlers {
                if let value = handler as? [String: Any],
                   let command = value["command"] as? String, !command.isEmpty { values.append(command) }
            }
        }
        return values
    }

    func allCommands(in value: Any) -> [String] {
        if let object = value as? [String: Any] {
            var values = object["command"].flatMap { $0 as? String }.map { [$0] } ?? []
            values += object.values.flatMap { allCommands(in: $0) }
            return values
        }
        if let array = value as? [Any] { return array.flatMap { allCommands(in: $0) } }
        return []
    }

    func containsOwnLike(in document: [String: Any], commands: [String]) -> Bool {
        allCommands(in: document).contains { isOwnLike($0, expected: commands) }
    }

    func isOwnLike(_ command: String, expected: [String]) -> Bool {
        if expected.contains(command) { return true }
        let value = command.lowercased()
        return value.contains("askkey") || value.contains("ask key") || value.contains(format.invocationMarker)
    }

    func readSnapshot(at url: URL, checkParent: Bool) throws -> Snapshot? {
        if checkParent { try inspectDirectory(url.deletingLastPathComponent(), error: .unsafeHooksFile) }
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result != 0 {
            guard errno == ENOENT else { throw Error.unsafeHooksFile }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else {
            throw Error.unsafeHooksFile
        }
        do {
            let file = try ClientConfigFileIO.readRegularFile(url, maximumBytes: Self.maximumHooksBytes)
            return Snapshot(bytes: file.bytes, mode: UInt32(file.mode))
        } catch ClientConfigFileIO.Failure.tooLarge {
            throw Error.fileTooLarge
        } catch ClientConfigFileIO.Failure.notFound {
            return nil
        } catch { throw Error.unsafeHooksFile }
    }

    func inspectDirectory(_ url: URL, error: Error) throws {
        let leaf = url.standardizedFileURL.path
        for current in pathPrefixes(of: url) {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                if current.path == leaf, info.st_uid != getuid() { throw error }
                continue
            }
            guard errno == ENOENT else { throw error }
        }
    }

    /// Return every path component without resolving symlinks. Calling lstat
    /// for only the leaf would allow an existing directory below a symlinked
    /// ancestor to pass the safety check.
    func pathPrefixes(of url: URL) -> [URL] {
        let components = url.standardizedFileURL.pathComponents
        var path = ""
        var prefixes: [URL] = []
        for component in components {
            if component == "/" {
                path = "/"
            } else if path.isEmpty {
                path = component
            } else if path == "/" {
                path += component
            } else {
                path += "/" + component
            }
            prefixes.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return prefixes
    }

    func ensureDirectory(_ url: URL, error: Error) throws {
        let standardizedURL = url.standardizedFileURL
        var missing: [URL] = []
        for current in pathPrefixes(of: standardizedURL) {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                if current.path == standardizedURL.path, info.st_uid != getuid() { throw error }
                continue
            }
            guard errno == ENOENT else { throw error }
            missing.append(current)
        }
        // `pathPrefixes` is root-to-leaf, so create parents before children.
        for directory in missing {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                var info = stat()
                guard directory.path.withCString({ lstat($0, &info) }) == 0,
                      (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw error }
            }
            var info = stat()
            guard directory.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw error }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path
                )
            } catch { throw error }
        }
    }

    /// macOS exposes /tmp and /var as root-owned aliases into /private. Keep
    /// those two OS aliases usable while refusing arbitrary user symlinks.
    func trustedSystemAlias(_ url: URL, info: stat) -> Bool {
        // `url` comes from `pathPrefixes`, whose component spelling is the
        // spelling that lstat just inspected. Do not let Foundation rewrite
        // `/var` or `/tmp` while deciding whether this link is trusted.
        let path = url.path
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
            linkBytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.readlink(
                    pathPointer,
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    rawBuffer.count
                )
            }
        }
        guard linkLength >= 0,
              String(decoding: linkBytes.prefix(Int(linkLength)), as: UTF8.self) == expectedLink else {
            return false
        }

        var targetInfo = stat()
        guard expectedTarget.withCString({ lstat($0, &targetInfo) }) == 0,
              (targetInfo.st_mode & S_IFMT) == S_IFDIR,
              targetInfo.st_uid == 0 else {
            return false
        }
        return true
    }

    func prepareBackupDirectory() throws {
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

    func writeBackup(_ data: Data, to url: URL) throws {
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

    func replace(
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

    func restore(_ quarantine: URL) throws {
        guard !FileManager.default.fileExists(atPath: hooksURL.path) else { throw Error.rollbackFailed }
        do { try ClientConfigFileIO.renameExclusively(from: quarantine, to: hooksURL) }
        catch { throw Error.rollbackFailed }
    }

    func rollback(plan: CommandDiscoveryHookPlan, replacement: Data) throws {
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

    func matches(_ snapshot: Snapshot?, bytes: Data?, mode: UInt32?) -> Bool {
        guard let bytes else { return snapshot == nil }
        return snapshot?.bytes == bytes && snapshot?.mode == mode
    }
}
