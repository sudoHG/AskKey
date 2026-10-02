import Foundation
import XCTest
@testable import AskKeyBroker

final class DebugRunDirectoryTests: XCTestCase {
    func testPrivateTmpDirectoryIsAcceptedWithoutRewritingItToSymlink() throws {
        let root = URL(fileURLWithPath: "/private/tmp/askkey-isolation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try DebugRunDirectory.resolve(
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        XCTAssertEqual(result?.path, root.path)
        XCTAssertThrowsError(try DebugRunDirectory.resolve(
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
    }
}
