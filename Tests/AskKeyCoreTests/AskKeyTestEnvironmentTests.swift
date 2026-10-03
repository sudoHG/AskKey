import Darwin
import Foundation
import XCTest

final class AskKeyTestEnvironmentTests: XCTestCase {
    func testExplicitRestoreWorksWhileScopeIsRetainedAndIsIdempotent() {
        let key = "ASKKEY_ENVIRONMENT_RESTORE_TEST"
        let original = ProcessInfo.processInfo.environment[key]
        defer {
            if let original { setenv(key, original, 1) } else { unsetenv(key) }
        }
        setenv(key, "synthetic-ambient", 1)
        let retained = AskKeyTestEnvironment()
        XCTAssertNil(ProcessInfo.processInfo.environment[key])

        retained.restore()
        XCTAssertEqual(ProcessInfo.processInfo.environment[key], "synthetic-ambient")

        setenv(key, "synthetic-next-scope", 1)
        retained.restore()
        XCTAssertEqual(ProcessInfo.processInfo.environment[key], "synthetic-next-scope")
        withExtendedLifetime(retained) {}
    }
}
