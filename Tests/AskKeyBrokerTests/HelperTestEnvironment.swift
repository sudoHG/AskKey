import Darwin
import Foundation

func helperTestEnvironment(overrides: [String: String]) -> [String: String] {
    ProcessInfo.processInfo.environment
        .filter { !$0.key.hasPrefix("ASKKEY_") }
        .merging(overrides) { _, fixture in fixture }
}

func physicalTestDirectory(_ directory: URL) throws -> URL {
    // Foundation can abbreviate /private/tmp back to its /tmp symlink.
    // DebugRunDirectory requires the physical spelling of every ancestor.
    guard let path = realpath(directory.resolvingSymlinksInPath().path, nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
