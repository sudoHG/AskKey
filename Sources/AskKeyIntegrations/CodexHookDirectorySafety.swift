import Darwin
import Foundation

/// Checks every ancestor before Codex hook configuration or backup access.
/// Inspect the original spelling so a user symlink cannot disappear during
/// path normalization, even when its child directory already exists.
enum CodexHookDirectorySafety {
    static func inspect<Failure: Error>(_ url: URL, error: Failure) throws {
        let path = url.path
        guard url.isFileURL, path.hasPrefix("/") else { throw error }
        var prefixes = ["/"]
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + String(component)
            prefixes.append(prefix)
        }
        for current in prefixes {
            var info = stat()
            if current.withCString({ lstat($0, &info) }) == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                } else {
                    guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                }
            } else {
                guard errno == ENOENT else { throw error }
            }
        }
    }

    /// Only macOS's root-owned /tmp and /var aliases are accepted. Never
    /// resolve the complete user path to decide whether a link is safe.
    private static func trustedSystemAlias(_ path: String, info: stat) -> Bool {
        let expectedLink: String
        let expectedTarget: String
        switch path {
        case "/tmp":
            expectedLink = "private/tmp"
            expectedTarget = "/private/tmp"
        case "/var":
            expectedLink = "private/var"
            expectedTarget = "/private/var"
        default:
            return false
        }
        guard info.st_uid == 0 else { return false }

        var linkBytes = [UInt8](repeating: 0, count: 1024)
        let linkLength = path.withCString { pathPointer in
            linkBytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.readlink(pathPointer, base.assumingMemoryBound(to: CChar.self), buffer.count)
            }
        }
        guard linkLength >= 0,
              String(decoding: linkBytes.prefix(linkLength), as: UTF8.self) == expectedLink else {
            return false
        }

        var targetInfo = stat()
        return expectedTarget.withCString({ lstat($0, &targetInfo) }) == 0
            && (targetInfo.st_mode & S_IFMT) == S_IFDIR
            && targetInfo.st_uid == 0
    }
}
