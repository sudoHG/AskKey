#if DEBUG
import CryptoKit
import Darwin
import Foundation
import AskKeyBroker

/// Only selected by an explicitly configured isolated Debug run. These are
/// synthetic test keys, never the production login-keychain material.
final class DebugRunMigrationKeyStore: MigrationKeyStore {
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
        if !FileManager.default.fileExists(atPath: self.directory.path) {
            try FileManager.default.createDirectory(
                at: self.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try verifyFile(self.directory, isDirectory: true)
    }

    func loadLegacyKey() throws -> Data { try load(legacyService, missing: .missingLegacyKey) }
    func loadPendingKey() throws -> Data { try load(pendingService, missing: .missingPendingKey) }
    func loadAppKey() throws -> Data { try load(appService, missing: .missingAppKey) }
    func savePendingKey(_ data: Data) throws { try save(data, service: pendingService) }
    func promotePendingKey() throws { try save(loadPendingKey(), service: appService) }
    func deleteLegacyKey() throws { try delete(legacyService) }
    func deletePendingKey() throws { try delete(pendingService) }
    func deleteAppKey() throws { try delete(appService) }

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

    private func load(_ service: String, missing: MigrationKeyStoreError) throws -> Data {
        let url = file(service)
        guard FileManager.default.fileExists(atPath: url.path) else { throw missing }
        try verifyFile(directory, isDirectory: true)
        try verifyFile(url)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw DebugRunDirectoryError.invalidDirectory }
        defer { Darwin.close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = Darwin.read(descriptor, &bytes, 33)
        guard count == 32 else { throw MigrationKeyStoreError.conflictingKey }
        return Data(bytes.prefix(32))
    }

    private func save(_ data: Data, service: String) throws {
        guard data.count == 32 else { throw MigrationKeyStoreError.conflictingKey }
        try verifyFile(directory, isDirectory: true)
        let url = file(service)
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            guard errno == EEXIST, try load(service, missing: .conflictingKey) == data else {
                throw MigrationKeyStoreError.conflictingKey
            }
            return
        }
        defer { Darwin.close(descriptor) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        guard count == data.count, fsync(descriptor) == 0 else {
            _ = url.path.withCString { Darwin.unlink($0) }
            throw MigrationKeyStoreError.conflictingKey
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
