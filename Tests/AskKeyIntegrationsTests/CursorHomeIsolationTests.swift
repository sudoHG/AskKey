import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

final class CursorHomeIsolationTests: CursorUserMCPAdapterTests {
    func testDoesNotReadRealHomeCursorMCPJSON() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let needle = ["homeDirectory", "ForCurrentUser"].joined()
        XCTAssertFalse(source.contains(needle), "adapter tests must not snapshot Hogan's ~/.cursor/mcp.json")
    }
}
