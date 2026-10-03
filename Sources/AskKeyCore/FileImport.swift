import CryptoKit
import Darwin
import Foundation

public enum FileImport {
    public static let maxByteCount = 5 * 1024 * 1024

    public struct FrozenFile: Equatable, Sendable {
        public let originalFilename: String
        public let bytes: Data
        public let byteSize: Int
        public let contentDigest: Data

        public init(originalFilename: String, bytes: Data) throws {
            guard !originalFilename.isEmpty, originalFilename.utf8.count <= 255 else {
                throw VaultError.invalidFileCredential(.notFound)
            }
            guard bytes.count <= FileImport.maxByteCount else {
                throw VaultError.invalidFileCredential(.tooLarge)
            }
            self.originalFilename = originalFilename
            self.bytes = bytes
            byteSize = bytes.count
            contentDigest = Data(SHA256.hash(data: bytes))
        }

        init(originalFilename: String, bytes: Data, byteSize: Int, contentDigest: Data) {
            self.originalFilename = originalFilename
            self.bytes = bytes
            self.byteSize = byteSize
            self.contentDigest = contentDigest
        }
    }

    enum FreezeCheckpoint: Equatable {
        case afterPathCheck
        case afterOpen
    }

    public static func freeze(url: URL) throws -> FrozenFile {
        try freeze(url: url, checkpoint: { _ in })
    }

    static func freeze(url: URL, checkpoint: (FreezeCheckpoint) throws -> Void) throws -> FrozenFile {
        let expected = try identity(at: url)
        try rejectIfNotImportable(expected)
        try checkpoint(.afterPathCheck)

        let fd = url.path.withCString { path in
            // A path that passed lstat can still be replaced before open. Keep
            // special files such as FIFOs from making this synchronous import
            // wait for an unrelated writer; fstat below remains authoritative.
            Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            throw VaultError.invalidFileCredential(.replacedDuringRead)
        }
        defer { Darwin.close(fd) }

        let opened = try identity(fd: fd)
        try rejectIfNotImportable(opened)
        guard opened == expected else {
            throw VaultError.invalidFileCredential(.replacedDuringRead)
        }
        try checkpoint(.afterOpen)

        let bytes = try read(fd: fd)
        let after = try identity(fd: fd)
        guard after == expected, bytes.count == expected.size else {
            throw VaultError.invalidFileCredential(.replacedDuringRead)
        }
        return try FrozenFile(originalFilename: url.lastPathComponent, bytes: bytes)
    }
}

private struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int
    let mode: mode_t
    let mtimeSec: Int64
    let mtimeNsec: Int64
    let ctimeSec: Int64
    let ctimeNsec: Int64
}

private func identity(at url: URL) throws -> FileIdentity {
    var st = stat()
    let result = url.path.withCString { lstat($0, &st) }
    guard result == 0 else {
        throw VaultError.invalidFileCredential(.notFound)
    }
    return try fileIdentity(from: st)
}

private func identity(fd: Int32) throws -> FileIdentity {
    var st = stat()
    guard fstat(fd, &st) == 0 else {
        throw VaultError.invalidFileCredential(.notFound)
    }
    return try fileIdentity(from: st)
}

private func fileIdentity(from st: stat) throws -> FileIdentity {
    guard let size = Int(exactly: st.st_size) else {
        throw VaultError.invalidFileCredential(.tooLarge)
    }
    return FileIdentity(
        device: UInt64(bitPattern: Int64(st.st_dev)),
        inode: st.st_ino,
        size: size,
        mode: st.st_mode,
        mtimeSec: Int64(st.st_mtimespec.tv_sec),
        mtimeNsec: Int64(st.st_mtimespec.tv_nsec),
        ctimeSec: Int64(st.st_ctimespec.tv_sec),
        ctimeNsec: Int64(st.st_ctimespec.tv_nsec)
    )
}

private func rejectIfNotImportable(_ identity: FileIdentity) throws {
    let type = identity.mode & S_IFMT
    if type == S_IFLNK {
        throw VaultError.invalidFileCredential(.symbolicLink)
    }
    if type == S_IFDIR {
        throw VaultError.invalidFileCredential(.directory)
    }
    if type != S_IFREG {
        throw VaultError.invalidFileCredential(.specialFile)
    }
    if identity.size > FileImport.maxByteCount {
        throw VaultError.invalidFileCredential(.tooLarge)
    }
}

private func read(fd: Int32) throws -> Data {
    var data = Data()
    let chunkSize = 65_536
    var buffer = [UInt8](repeating: 0, count: chunkSize)
    while true {
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return Darwin.read(fd, base, chunkSize)
        }
        if n == 0 { break }
        if n < 0 {
            throw VaultError.invalidFileCredential(.notFound)
        }
        data.append(buffer, count: n)
        if data.count > FileImport.maxByteCount {
            throw VaultError.invalidFileCredential(.tooLarge)
        }
    }
    return data
}
