import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Shared no-follow read and exclusive publish for client config files.
/// Codex / Cursor / Grok keep their own format, probe, and status mapping.
///
/// Still unshared — client semantics differ, not leftover copies:
/// - Process spawn / timeout / kill: Codex and Grok share `RestrictedProcess`
///   (posix_spawn, private group, CLOEXEC, wait, group cleanup). Each keeps its
///   timeout, cwd, stderr, input timing, overflow, and TERM grace. Cursor
///   `probeMCP` keeps Foundation `Process` and terminate-then-SIGKILL.
///   Consumers: those adapters. Failures stay in each adapter's connection tests.
/// - MCP initialize / tools: Codex / Cursor / Grok share `MCPHelperContract`
///   for initialize + tools/list request/response checks. Each keeps its
///   clientInfo (Cursor `cursor`, Codex `askkey` 0.1.0, Grok `askkey` 0).
///   Runners stay per client. Cursor's long-lived Process path is unchanged.
/// - Backup ownership: Cursor process lock + quarantine rollback;
///   Codex writes a JSONEncoder journal (filename may still be config.toml);
///   Grok uses its own directory + TOML backup/restore paths.
enum ClientConfigFileIO {
    struct RegularFile: Equatable, Sendable {
        var bytes: Data
        var mode: mode_t
    }

    enum Failure: Error, Equatable {
        case notFound
        case unsafe
        case tooLarge
        case writeFailed
        case exclusiveExists
    }

    static func inspectRegularFile(_ url: URL) throws -> mode_t? {
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.unsafe
        }
        if (info.st_mode & S_IFMT) != S_IFREG { throw Failure.unsafe }
        return info.st_mode & 0o777
    }

    static func readRegularFile(_ url: URL, maximumBytes: Int? = nil) throws -> RegularFile {
        let fd = try openRegularFile(url)
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.unsafe
        }
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            if count < 0 { throw Failure.unsafe }
            bytes.append(buffer, count: count)
            if let maximumBytes, bytes.count > maximumBytes {
                throw Failure.tooLarge
            }
        }
        return RegularFile(bytes: bytes, mode: info.st_mode & 0o777)
    }

    private static func openRegularFile(_ url: URL) throws -> Int32 {
        while true {
            let fd = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            }
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            if errno == ENOENT { throw Failure.notFound }
            throw Failure.unsafe
        }
    }

    static func writeExclusiveTemporary(
        _ data: Data,
        in directory: URL,
        prefix: String,
        didCreate: ((URL) -> Void)? = nil
    ) throws -> URL {
#if DEBUG
        OnboardingBoundaryObserver.note(.configWrite)
#endif
        let temporary = directory.appendingPathComponent("\(prefix)\(UUID().uuidString)")
        let fd = temporary.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard fd >= 0 else { throw Failure.writeFailed }
        var openDescriptor = true
        defer {
            if openDescriptor { Darwin.close(fd) }
        }
        didCreate?(temporary)
        do {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else {
                    guard buffer.isEmpty else { throw Failure.writeFailed }
                    return
                }
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, base.advanced(by: offset), buffer.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.writeFailed }
                    offset += count
                }
            }
            guard fsync(fd) == 0 else { throw Failure.writeFailed }
            let closed = Darwin.close(fd)
            openDescriptor = false
            guard closed == 0 else { throw Failure.writeFailed }
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func publishAtomically(
        _ data: Data,
        to url: URL,
        mode: mode_t,
        exclusive: Bool,
        temporaryPrefix: String,
        didCreateTemporary: ((URL) -> Void)? = nil
    ) throws {
        let temporary = try writeExclusiveTemporary(
            data,
            in: url.deletingLastPathComponent(),
            prefix: temporaryPrefix,
            didCreate: didCreateTemporary
        )
        do {
            try rename(from: temporary, to: url, exclusive: exclusive)
            try FileManager.default.setAttributes(
                [.posixPermissions: Int(mode)],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func renameExclusively(from source: URL, to destination: URL) throws {
        try rename(from: source, to: destination, exclusive: true)
    }

    private static func rename(from source: URL, to destination: URL, exclusive: Bool) throws {
        let result = destination.path.withCString { destinationPath in
            source.path.withCString { sourcePath in
                exclusive
                    ? Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                    : Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            if exclusive, errno == EEXIST { throw Failure.exclusiveExists }
            throw Failure.writeFailed
        }
    }
}
