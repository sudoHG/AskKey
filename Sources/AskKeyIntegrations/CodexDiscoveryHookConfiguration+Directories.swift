import Darwin
import Foundation

extension CodexDiscoveryHookConfiguration {
    func inspectExistingDirectoryChain(
        _ url: URL,
        error: CodexDiscoveryHookConfigurationError
    ) throws {
        try CodexHookDirectorySafety.inspect(url, error: error)
    }

    func ensureDirectoryChain(
        _ url: URL,
        error: CodexDiscoveryHookConfigurationError
    ) throws {
        try inspectExistingDirectoryChain(url, error: error)
        var missing: [URL] = []
        var current = url
        while true {
            var info = stat()
            let result = current.path.withCString { lstat($0, &info) }
            if result == 0 {
                guard (info.st_mode & S_IFMT) == S_IFDIR else { throw error }
                break
            }
            let failure = errno
            guard failure == ENOENT else { throw error }
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { throw error }
            current = parent
        }

        for directory in missing.reversed() {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)]
                )
            } catch {
                var info = stat()
                let result = directory.path.withCString { lstat($0, &info) }
                guard result == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                    throw error
                }
            }
            var info = stat()
            guard directory.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else {
                throw error
            }
            do {
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)],
                    ofItemAtPath: directory.path
                )
            } catch {
                throw error
            }
        }
    }
}
