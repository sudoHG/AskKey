import Darwin
import Foundation

extension CommandDiscoveryHookConfiguration {
    func inspectDirectory(_ url: URL, error: Error) throws {
        let leaf = url.standardizedFileURL.path
        for current in pathPrefixes(of: url) {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                if current.path == leaf, info.st_uid != getuid() { throw error }
                if format == .claudeMerged, current.path == leaf, info.st_mode & 0o022 != 0 { throw error }
                continue
            }
            guard errno == ENOENT else { throw error }
        }
    }

    /// Return every path component without resolving symlinks. Calling lstat
    /// for only the leaf would allow an existing directory below a symlinked
    /// ancestor to pass the safety check.
    private func pathPrefixes(of url: URL) -> [URL] {
        let components = url.standardizedFileURL.pathComponents
        var path = ""
        var prefixes: [URL] = []
        for component in components {
            if component == "/" {
                path = "/"
            } else if path.isEmpty {
                path = component
            } else if path == "/" {
                path += component
            } else {
                path += "/" + component
            }
            prefixes.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return prefixes
    }

    func ensureDirectory(_ url: URL, error: Error) throws {
        let standardizedURL = url.standardizedFileURL
        var missing: [URL] = []
        for current in pathPrefixes(of: standardizedURL) {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                if (info.st_mode & S_IFMT) == S_IFLNK {
                    guard trustedSystemAlias(current, info: info) else { throw error }
                    continue
                }
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                if current.path == standardizedURL.path, info.st_uid != getuid() { throw error }
                if format == .claudeMerged, current.path == standardizedURL.path,
                   info.st_mode & 0o022 != 0 { throw error }
                continue
            }
            guard errno == ENOENT else { throw error }
            missing.append(current)
        }
        // `pathPrefixes` is root-to-leaf, so create parents before children.
        for directory in missing {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                var info = stat()
                guard directory.path.withCString({ lstat($0, &info) }) == 0,
                      (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw error }
            }
            var info = stat()
            guard directory.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw error }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path
                )
            } catch { throw error }
        }
    }

    /// macOS exposes /tmp and /var as root-owned aliases into /private. Keep
    /// those two OS aliases usable while refusing arbitrary user symlinks.
    private func trustedSystemAlias(_ url: URL, info: stat) -> Bool {
        // `url` comes from `pathPrefixes`, whose component spelling is the
        // spelling that lstat just inspected. Do not let Foundation rewrite
        // `/var` or `/tmp` while deciding whether this link is trusted.
        let path = url.path
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
            linkBytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.readlink(
                    pathPointer,
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    rawBuffer.count
                )
            }
        }
        guard linkLength >= 0,
              String(decoding: linkBytes.prefix(Int(linkLength)), as: UTF8.self) == expectedLink else {
            return false
        }

        var targetInfo = stat()
        guard expectedTarget.withCString({ lstat($0, &targetInfo) }) == 0,
              (targetInfo.st_mode & S_IFMT) == S_IFDIR,
              targetInfo.st_uid == 0 else {
            return false
        }
        return true
    }
}
