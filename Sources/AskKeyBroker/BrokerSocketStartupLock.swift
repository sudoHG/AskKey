import Darwin
import Foundation

/// Serializes cooperating servers from the stale-path probe through listen().
/// Never unlink this side file: another process may already have it open.
final class BrokerSocketStartupLock {
    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    static func acquire(for socketPath: String) throws -> BrokerSocketStartupLock {
        let descriptor = open(socketPath + ".startup.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BrokerSocketError.systemError("open startup lock", errno) }
        var owned = false
        defer { if !owned { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else {
            throw BrokerSocketError.systemError("unsafe startup lock", EACCES)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw BrokerSocketError.systemError("lock socket startup", errno)
        }
        owned = true
        return BrokerSocketStartupLock(descriptor)
    }
}
