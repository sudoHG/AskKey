import Darwin
import Foundation

/// The descriptor owns the lock; the path must remain in place after release.
final class LibraryInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    static func acquire(in directory: URL) throws -> LibraryInstanceLock? {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("instance.lock").path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var owned = false
        defer { if !owned { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(.EACCES)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        owned = true
        return LibraryInstanceLock(descriptor: descriptor)
    }
}
