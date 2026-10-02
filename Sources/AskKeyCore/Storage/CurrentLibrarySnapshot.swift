import Darwin
import Foundation

/// Only credentials-v2.db and its SQLite WAL are copied. SQLite never opens
/// the originals during preflight, including for read-only validation.
enum CurrentLibrarySnapshot {
    struct Proof: Equatable {
        fileprivate let files: [String: ObservedFile]

        func validate(_ source: URL) throws {
            guard try CurrentLibrarySnapshot.contents(source) == self else {
                throw VaultBootstrapError.invalidState
            }
        }
    }

    fileprivate struct ObservedFile: Equatable {
        let device: dev_t
        let inode: ino_t
        let bytes: Data
    }

    static func regularFileExists(_ url: URL) throws -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else {
            if errno == ENOENT { return false }
            throw VaultBootstrapError.invalidState
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw VaultBootstrapError.invalidState }
        return true
    }

    static func withCopy<T>(of source: URL, _ body: (URL) throws -> T) throws -> T {
        try withVerifiedCopy(of: source) { destination, _ in try body(destination) }
    }

    static func withVerifiedCopy<T>(of source: URL, _ body: (URL, Proof) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyCurrentLibrary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let destination = directory.appendingPathComponent("credentials-v2.db")
            let before = try contents(source)
            guard before.files[""] != nil else { throw VaultBootstrapError.missingDatabase }
            for (suffix, file) in before.files {
                let url = URL(fileURLWithPath: destination.path + suffix)
                try file.bytes.write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            guard try contents(source) == before else { throw VaultBootstrapError.invalidState }
            let result = try body(destination, before)
            guard try contents(source) == before else { throw VaultBootstrapError.invalidState }
            try FileManager.default.removeItem(at: directory)
            return result
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func contents(_ source: URL) throws -> Proof {
        // A hot rollback journal cannot be safely inspected by opening its
        // original database. Current libraries use WAL; preserve and reject it.
        guard try !regularFileExists(URL(fileURLWithPath: source.path + "-journal")) else {
            throw VaultBootstrapError.invalidState
        }
        _ = try regularFileExists(URL(fileURLWithPath: source.path + "-shm"))
        var files: [String: ObservedFile] = [:]
        for suffix in ["", "-wal"] {
            let url = URL(fileURLWithPath: source.path + suffix)
            guard try regularFileExists(url) else { continue }
            let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
            guard descriptor >= 0 else { throw VaultBootstrapError.invalidState }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(descriptor)
                throw VaultBootstrapError.invalidState
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let bytes = try handle.readToEnd() ?? Data()
            var after = stat()
            guard fstat(descriptor, &after) == 0,
                  info.st_size == after.st_size,
                  info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  info.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  info.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw VaultBootstrapError.invalidState
            }
            files[suffix] = ObservedFile(device: info.st_dev, inode: info.st_ino, bytes: bytes)
            try handle.close()
        }
        return Proof(files: files)
    }
}
