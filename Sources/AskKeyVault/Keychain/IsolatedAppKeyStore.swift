#if DEBUG
import CryptoKit
import Darwin
import Foundation
import AskKeyBroker

/// Only selected by an explicitly configured isolated Debug run. These are
/// synthetic test keys, never the production login-keychain material.
final class IsolatedAppKeyStore: AppKeyStore {
    private let directory: URL
    private let legacyService: String
    private let pendingService: String
    private let appService: String

    init(directory: URL, legacyService: String, pendingService: String, appService: String) throws {
        guard try DebugRunDirectory.resolve() == directory else {
            throw DebugRunDirectoryError.invalidDirectory
        }
        self.directory = directory.appendingPathComponent("key-material", isDirectory: true)
        self.legacyService = legacyService
        self.pendingService = pendingService
        self.appService = appService
        if FileManager.default.fileExists(atPath: self.directory.path) {
            try verifyFile(self.directory, isDirectory: true)
        }
    }

    func loadPendingKey() throws -> Data { try load(pendingService, missing: .missingPendingKey) }
    func loadAppKey() throws -> Data { try load(appService, missing: .missingAppKey) }
    func savePendingKey(_ data: Data) throws { try save(data, service: pendingService) }
    func promotePendingKey() throws { try save(loadPendingKey(), service: appService) }
    func deleteLegacyKey() throws { try delete(legacyService) }
    func deletePendingKey() throws { try delete(pendingService) }
    func deleteAppKey() throws { try delete(appService) }

    private var policyService: String { appService + "\0agent-access-policy" }

    func loadAgentAccessPolicy() throws -> Data? {
        let url = file(policyService)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try verifyFile(directory, isDirectory: true)
        try verifyFile(url)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw DebugRunDirectoryError.invalidDirectory }
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 65_537)
        var count = 0
        while count < bytes.count {
            let size = bytes.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), $0.count - count)
            }
            if size < 0, errno == EINTR { continue }
            guard size >= 0 else { throw DebugRunDirectoryError.invalidDirectory }
            if size == 0 { break }
            count += size
        }
        guard count <= 65_536 else { throw AppKeyStoreError.conflictingKey }
        return Data(bytes.prefix(count))
    }

    func saveAgentAccessPolicy(_ data: Data) throws {
        guard data.count <= 65_536 else { throw AppKeyStoreError.conflictingKey }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        try verifyFile(directory, isDirectory: true)
        let target = file(policyService)
        if FileManager.default.fileExists(atPath: target.path) { try verifyFile(target) }
        let temporary = directory.appendingPathComponent("policy-\(UUID().uuidString).creating")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw DebugRunDirectoryError.invalidDirectory }
        defer {
            Darwin.close(descriptor)
            _ = temporary.path.withCString { Darwin.unlink($0) }
        }
        var offset = 0
        while offset < data.count {
            let size = data.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset)
            }
            if size < 0, errno == EINTR { continue }
            guard size > 0 else { throw AppKeyStoreError.conflictingKey }
            offset += size
        }
        guard fsync(descriptor) == 0,
              temporary.path.withCString({ source in target.path.withCString { Darwin.rename(source, $0) } }) == 0 else {
            throw AppKeyStoreError.conflictingKey
        }
    }

    func deleteAgentAccessPolicy() throws { try delete(policyService) }

    private func file(_ service: String) -> URL {
        let name = SHA256.hash(data: Data(service.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".key")
    }

    private func verifyFile(_ url: URL, isDirectory: Bool = false) throws {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_uid == geteuid(),
              info.st_mode & S_IFMT == (isDirectory ? S_IFDIR : S_IFREG),
              info.st_mode & 0o777 == (isDirectory ? 0o700 : 0o600) else {
            throw DebugRunDirectoryError.invalidDirectory
        }
    }

    private func load(_ service: String, missing: AppKeyStoreError) throws -> Data {
        let url = file(service)
        guard FileManager.default.fileExists(atPath: url.path) else { throw missing }
        try verifyFile(directory, isDirectory: true)
        try verifyFile(url)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw DebugRunDirectoryError.invalidDirectory }
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = Darwin.read(descriptor, &bytes, 33)
        guard count == 32 else { throw AppKeyStoreError.conflictingKey }
        return Data(bytes.prefix(32))
    }

    private func save(_ data: Data, service: String) throws {
        guard data.count == 32 else { throw AppKeyStoreError.conflictingKey }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        }
        try verifyFile(directory, isDirectory: true)
        let url = file(service)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            guard errno == EEXIST, try load(service, missing: .conflictingKey) == data else {
                throw AppKeyStoreError.conflictingKey
            }
            return
        }
        defer { Darwin.close(descriptor) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(descriptor) == 0 else {
            _ = url.path.withCString { Darwin.unlink($0) }
            throw AppKeyStoreError.conflictingKey
        }
    }

    private func delete(_ service: String) throws {
        let url = file(service)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try verifyFile(directory, isDirectory: true)
        try verifyFile(url)
        guard url.path.withCString({ Darwin.unlink($0) }) == 0 else {
            throw DebugRunDirectoryError.invalidDirectory
        }
    }
}
#endif
