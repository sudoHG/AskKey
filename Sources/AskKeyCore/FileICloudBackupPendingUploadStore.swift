import Darwin
import Foundation

/// Stores only the coordinator's authenticated encrypted journal, never a
/// recovery key or plaintext credential. Synchronize before a cloud claim.
final class FileICloudBackupPendingUploadStore {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    func read(namespace: String) throws -> Data? {
        let name = try filename(namespace)
        guard let directoryFD = try openDirectory(create: false) else { return nil }
        defer { Darwin.close(directoryFD) }
        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw failure()
        }
        defer { Darwin.close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw ICloudBackupError.invalidPendingUpload
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    func write(_ data: Data?, namespace: String) throws {
        let name = try filename(namespace)
        guard let directoryFD = try openDirectory(create: data != nil) else { return }
        defer { Darwin.close(directoryFD) }
        guard let data else {
            if Darwin.unlinkat(directoryFD, name, 0) != 0, errno != ENOENT { throw failure() }
            guard fsync(directoryFD) == 0 else { throw failure() }
            return
        }
        let temporary = ".\(UUID().uuidString).pending"
        let fd = Darwin.openat(
            directoryFD, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard fd >= 0 else { throw failure() }
        defer {
            Darwin.close(fd)
            _ = Darwin.unlinkat(directoryFD, temporary, 0)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw ICloudBackupError.invalidPendingUpload }
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw failure() }
            }
        }
        guard fsync(fd) == 0 else { throw failure() }
        guard Darwin.renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw failure() }
        guard fsync(directoryFD) == 0 else { throw failure() }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        if create {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if !create, errno == ENOENT { return nil }
            throw failure()
        }
        do {
            var metadata = stat()
            guard fstat(fd, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  metadata.st_uid == getuid(),
                  metadata.st_mode & 0o077 == 0 else {
                throw ICloudBackupError.invalidPendingUpload
            }
            if create {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                var mutableDirectory = directory
                try mutableDirectory.setResourceValues(values)
                let parent = Darwin.open(
                    directory.deletingLastPathComponent().path,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard parent >= 0 else { throw failure() }
                defer { Darwin.close(parent) }
                guard fsync(parent) == 0 else { throw failure() }
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func filename(_ namespace: String) throws -> String {
        guard namespace.count == 32,
              namespace.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ICloudBackupError.invalidPendingUpload
        }
        return namespace + ".upload"
    }

    private func failure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
