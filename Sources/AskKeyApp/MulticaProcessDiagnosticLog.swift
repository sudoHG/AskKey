import Darwin
import Foundation

/// Persists the bounded, non-sensitive metadata produced by a Multica CLI run.
///
/// The caller supplies the directory so that this type never chooses a data
/// location. The writer never receives process output, arguments, or the
/// environment; a record contains only counters and fixed diagnostic values.
enum MulticaProcessDiagnosticLog {
    struct Record: Codable, Equatable, Sendable {
        let operation: String
        let exit: Int32?
        let stdoutBytes: Int
        let stderrBytes: Int
        let validJSON: Bool
        let failure: String?
        let stage: String?
        let systemError: Int32?
        let durationMilliseconds: Int?

        init(
            operation: String,
            exit: Int32? = nil,
            stdoutBytes: Int,
            stderrBytes: Int,
            validJSON: Bool,
            failure: String? = nil,
            stage: String? = nil,
            systemError: Int32? = nil,
            durationMilliseconds: Int? = nil
        ) {
            self.operation = operation
            self.exit = exit
            self.stdoutBytes = stdoutBytes
            self.stderrBytes = stderrBytes
            self.validJSON = validJSON
            self.failure = failure
            self.stage = stage
            self.systemError = systemError
            self.durationMilliseconds = durationMilliseconds
        }
    }

    private struct Entry {
        let name: String
        let seconds: Int64
        let nanoseconds: Int64
    }

    private enum Failure: Error {
        case unsafeDirectory
        case io
    }

    private static let lock = NSLock()
    private static let retentionLimit = 32
    private static let maximumRecordBytes = 64 * 1024
    private static let filePrefix = "askkey-multica-"

    /// Writes one metadata record and returns false for every I/O or encoding
    /// failure. Diagnostics must never change the Multica check outcome.
    @discardableResult
    static func write(_ record: Record, directory: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(record)
            guard data.count <= maximumRecordBytes else { return false }

            let directoryFD = try openSecureDirectory(directory)
            defer { Darwin.close(directoryFD) }

            let temporaryName = ".askkey-multica-diagnostic-\(UUID().uuidString).tmp"
            let finalName = "\(filePrefix)\(UUID().uuidString).json"
            let descriptor = temporaryName.withCString {
                Darwin.openat(
                    directoryFD,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    S_IRUSR | S_IWUSR
                )
            }
            guard descriptor >= 0 else { throw Failure.io }

            var descriptorOpen = true
            defer {
                if descriptorOpen { Darwin.close(descriptor) }
                _ = temporaryName.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            }

            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0,
                  Darwin.close(descriptor) == 0 else {
                throw Failure.io
            }
            descriptorOpen = false

            let published = temporaryName.withCString { source in
                finalName.withCString { destination in
                    renameatx_np(
                        directoryFD,
                        source,
                        directoryFD,
                        destination,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard published == 0, fsync(directoryFD) == 0 else { throw Failure.io }

            try trim(directoryFD: directoryFD)
            return true
        } catch {
            return false
        }
    }

    private static func openSecureDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw Failure.unsafeDirectory }
        let path = url.standardizedFileURL.path
        guard !path.isEmpty, path != "/", !path.utf8.contains(0) else {
            throw Failure.unsafeDirectory
        }

        let absolute = path.hasPrefix("/")
        var current = Darwin.open(
            absolute ? "/" : ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard current >= 0 else { throw Failure.unsafeDirectory }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            Darwin.close(current)
            throw Failure.unsafeDirectory
        }

        do {
            for (index, component) in components.enumerated() {
                let name = String(component)
                var info = stat()
                let inspected = name.withCString {
                    fstatat(current, $0, &info, AT_SYMLINK_NOFOLLOW)
                }
                let next: Int32

                if inspected == 0 {
                    if (info.st_mode & S_IFMT) == S_IFLNK {
                        guard absolute, index == 0,
                              let aliasFD = openTrustedSystemAlias(parent: current, name: name) else {
                            throw Failure.unsafeDirectory
                        }
                        next = aliasFD
                    } else {
                        guard (info.st_mode & S_IFMT) == S_IFDIR else {
                            throw Failure.unsafeDirectory
                        }
                        next = name.withCString {
                            Darwin.openat(
                                current,
                                $0,
                                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                            )
                        }
                        guard next >= 0 else { throw Failure.unsafeDirectory }
                    }
                } else {
                    guard errno == ENOENT else { throw Failure.unsafeDirectory }
                    let made = name.withCString { Darwin.mkdirat(current, $0, S_IRWXU) }
                    guard made == 0 || errno == EEXIST else { throw Failure.unsafeDirectory }
                    next = name.withCString {
                        Darwin.openat(
                            current,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                        )
                    }
                    guard next >= 0 else { throw Failure.unsafeDirectory }
                }

                var openedInfo = stat()
                guard fstat(next, &openedInfo) == 0,
                      (openedInfo.st_mode & S_IFMT) == S_IFDIR else {
                    Darwin.close(next)
                    throw Failure.unsafeDirectory
                }
                if index == components.count - 1 {
                    guard openedInfo.st_uid == getuid(),
                          fchmod(next, S_IRWXU) == 0 else {
                        Darwin.close(next)
                        throw Failure.unsafeDirectory
                    }
                    var securedInfo = stat()
                    guard fstat(next, &securedInfo) == 0,
                          securedInfo.st_uid == getuid(),
                          (securedInfo.st_mode & S_IFMT) == S_IFDIR,
                          securedInfo.st_mode & 0o777 == 0o700 else {
                        Darwin.close(next)
                        throw Failure.unsafeDirectory
                    }
                }

                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    /// `/var` and `/tmp` are root-owned macOS aliases. Open their real target
    /// by descriptor after checking the exact link, while rejecting all other
    /// symlinks in the supplied path.
    private static func openTrustedSystemAlias(parent: Int32, name: String) -> Int32? {
        guard name == "var" || name == "tmp" else { return nil }

        var linkBytes = [UInt8](repeating: 0, count: 64)
        let linkLength = name.withCString { linkName in
            linkBytes.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return readlinkat(
                    parent,
                    linkName,
                    base.assumingMemoryBound(to: CChar.self),
                    raw.count
                )
            }
        }
        guard linkLength >= 0,
              String(decoding: linkBytes.prefix(linkLength), as: UTF8.self) == "private/\(name)" else {
            return nil
        }

        let privateFD = "private".withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard privateFD >= 0 else { return nil }
        defer { Darwin.close(privateFD) }

        var targetInfo = stat()
        let targetInspected = name.withCString {
            fstatat(privateFD, $0, &targetInfo, AT_SYMLINK_NOFOLLOW)
        }
        guard targetInspected == 0,
              (targetInfo.st_mode & S_IFMT) == S_IFDIR,
              targetInfo.st_uid == 0 else { return nil }
        return name.withCString {
            Darwin.openat(
                privateFD,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                guard raw.isEmpty else { throw Failure.io }
                return
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw Failure.io
                }
            }
        }
    }

    private static func trim(directoryFD: Int32) throws {
        let entries = try ownedEntries(directoryFD: directoryFD)
        guard entries.count > retentionLimit else { return }

        let oldest = entries.sorted {
            if $0.seconds != $1.seconds { return $0.seconds < $1.seconds }
            if $0.nanoseconds != $1.nanoseconds { return $0.nanoseconds < $1.nanoseconds }
            return $0.name < $1.name
        }
        for entry in oldest.prefix(entries.count - retentionLimit) {
            let removed = entry.name.withCString { Darwin.unlinkat(directoryFD, $0, 0) }
            guard removed == 0 || errno == ENOENT else { throw Failure.io }
        }
        guard fsync(directoryFD) == 0 else { throw Failure.io }
    }

    private static func ownedEntries(directoryFD: Int32) throws -> [Entry] {
        let duplicate = Darwin.dup(directoryFD)
        guard duplicate >= 0 else { throw Failure.io }
        guard let directory = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw Failure.io
        }
        defer { closedir(directory) }

        var entries: [Entry] = []
        while let pointer = readdir(directory) {
            let name = withUnsafeBytes(of: pointer.pointee.d_name) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
                return String(decoding: bytes[..<end], as: UTF8.self)
            }
            guard name.hasPrefix(filePrefix), name.hasSuffix(".json"),
                  UUID(uuidString: String(name.dropFirst(filePrefix.count).dropLast(5))) != nil else { continue }

            var info = stat()
            let inspected = name.withCString {
                fstatat(directoryFD, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            guard inspected == 0 else {
                if errno == ENOENT { continue }
                throw Failure.io
            }
            guard (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  info.st_nlink == 1,
                  info.st_mode & 0o077 == 0,
                  isDiagnosticRecord(name: name, directoryFD: directoryFD) else { continue }

            entries.append(
                Entry(
                    name: name,
                    seconds: Int64(info.st_mtimespec.tv_sec),
                    nanoseconds: Int64(info.st_mtimespec.tv_nsec)
                )
            )
        }
        return entries
    }

    private static func isDiagnosticRecord(name: String, directoryFD: Int32) -> Bool {
        let descriptor = name.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else { return false }

        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(descriptor, base, raw.count)
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, bytes.count + count <= maximumRecordBytes else { return false }
            bytes.append(buffer, count: count)
        }
        return (try? JSONDecoder().decode(Record.self, from: bytes)) != nil
    }
}
