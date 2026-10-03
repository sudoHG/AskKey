import Darwin
import Foundation
import XCTest

@MainActor
class AskKeyAppTestCase: XCTestCase {
    private var environment: AskKeyTestEnvironment?

    override func setUp() {
        super.setUp()
        environment = AskKeyTestEnvironment()
    }

    override func tearDown() {
        environment?.restore()
        environment = nil
        super.tearDown()
    }
}

/// Scope process-global overrides to fixtures that call production APIs which
/// read the environment internally. Tests using this scope run serially.
final class AskKeyTestEnvironment {
    private let original: [String: String]
    private var restored = false

    init(overrides: [String: String] = [:]) {
        original = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ASKKEY_") }
        for key in original.keys { unsetenv(key) }
        for (key, value) in overrides { setenv(key, value, 1) }
    }

    func restore() {
        guard !restored else { return }
        restored = true
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("ASKKEY_") {
            unsetenv(key)
        }
        for (key, value) in original { setenv(key, value, 1) }
    }

    deinit { restore() }
}

func appTestEnvironment() -> [String: String] {
    ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ASKKEY_") }
}

func physicalTestDirectory(_ directory: URL) throws -> URL {
    // Debug fixtures need physical ancestors, including Foundation's /tmp alias.
    guard let path = realpath(directory.resolvingSymlinksInPath().path, nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
