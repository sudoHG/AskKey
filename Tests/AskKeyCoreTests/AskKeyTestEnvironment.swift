import Darwin
import Foundation

/// Scope inherited AskKey overrides while adapters launch their helper probes.
/// The suite runs these process-global fixtures serially.
final class AskKeyTestEnvironment {
    private let original: [String: String]

    init() {
        original = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ASKKEY_") }
        for key in original.keys { unsetenv(key) }
    }

    deinit {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("ASKKEY_") {
            unsetenv(key)
        }
        for (key, value) in original { setenv(key, value, 1) }
    }
}

func physicalTestDirectory(_ directory: URL) throws -> URL {
    // Preserve physical ancestors even when Foundation abbreviates /private/tmp.
    guard let path = realpath(directory.resolvingSymlinksInPath().path, nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
