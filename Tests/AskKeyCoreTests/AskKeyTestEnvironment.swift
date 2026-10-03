import Darwin
import Foundation
import XCTest

class AskKeyCoreTestCase: XCTestCase {
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

    /// Keep explicit opt-in parameters readable without inheriting them in children.
    func requestedEnvironmentValue(_ key: String) -> String? {
        environment?.originalValue(for: key)
    }
}

/// Scope inherited AskKey overrides while adapters launch their helper probes.
/// The suite runs these process-global fixtures serially.
final class AskKeyTestEnvironment {
    private let original: [String: String]
    private var restored = false

    init() {
        original = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("ASKKEY_") }
        for key in original.keys { unsetenv(key) }
    }

    func originalValue(for key: String) -> String? { original[key] }

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

func physicalTestDirectory(_ directory: URL) throws -> URL {
    // Preserve physical ancestors even when Foundation abbreviates /private/tmp.
    guard let path = realpath(directory.resolvingSymlinksInPath().path, nil) else {
        throw CocoaError(.fileReadNoSuchFile)
    }
    defer { free(path) }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
}
