import CryptoKit
import Darwin
import Foundation

public enum DebugRunDirectoryError: Error, Equatable, LocalizedError {
    case invalidDirectory

    public var errorDescription: String? {
        "The isolated Debug run directory must be an existing, privately owned 0700 directory outside the real Ask Key data directory."
    }
}

/// Shared by the App/Core and thin helper without a dependency on Core.
public enum DebugRunDirectory {
    public static func resolve() throws -> URL? {
        #if DEBUG
        return try resolve(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        #else
        return nil
        #endif
    }

    static func resolve(environment: [String: String], homeDirectory: URL) throws -> URL? {
        guard let raw = environment["ASKKEY_DEBUG_RUN_DIRECTORY"] else { return nil }
        guard raw.hasPrefix("/"), !raw.utf8.contains(0),
              !raw.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw DebugRunDirectoryError.invalidDirectory
        }
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        guard root.pathComponents.count > 1 else { throw DebugRunDirectoryError.invalidDirectory }
        let support = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        for protected in [support.appendingPathComponent("AskKey"),
                          support.appendingPathComponent("com.sudohg.askkey.lifecycle")] {
            let path = protected.standardizedFileURL.path
            guard root.path != path, !root.path.hasPrefix(path + "/"),
                  !path.hasPrefix(root.path + "/") else {
                throw DebugRunDirectoryError.invalidDirectory
            }
        }
        var candidate = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            candidate.appendPathComponent(component, isDirectory: true)
            var info = stat()
            guard candidate.path.withCString({ lstat($0, &info) }) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else {
                throw DebugRunDirectoryError.invalidDirectory
            }
            if candidate.path == root.path {
                guard info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                    throw DebugRunDirectoryError.invalidDirectory
                }
            }
        }
        return root
    }

    public static func namespace(for directory: URL) -> String {
        SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
