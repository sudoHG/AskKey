import Darwin
import Foundation

struct BrokerSocketPathIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    static func read(_ path: String) throws -> Self? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw BrokerSocketError.systemError("lstat", errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            throw BrokerSocketError.systemError("socket path", EADDRINUSE)
        }
        return Self(device: info.st_dev, inode: info.st_ino)
    }

    func unlinkIfCurrent(_ path: String) {
        if (try? Self.read(path)) == self { unlink(path) }
    }

    static func removeStaleSocket(at path: String) throws {
        guard let identity = try read(path) else { return }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BrokerSocketError.systemError("socket", errno) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw BrokerSocketError.systemError("fcntl", errno)
        }
        var address = try makeBrokerAddress(path: path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let failure = errno
        guard result < 0, failure == ECONNREFUSED || failure == ENOENT else {
            throw BrokerSocketError.systemError("socket already in use", EADDRINUSE)
        }
        guard let current = try read(path) else { return }
        guard current == identity else {
            throw BrokerSocketError.systemError("socket changed", EADDRINUSE)
        }
        guard unlink(path) == 0 || errno == ENOENT else {
            throw BrokerSocketError.systemError("unlink", errno)
        }
    }
}
