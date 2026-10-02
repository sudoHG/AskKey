import Foundation
import XCTest
import AskKeyBroker
@testable import AskKeyApp

final class MulticaConfigurationSerializationTests: XCTestCase {
    func testAppConfigurationSerializesOnlyTheIsolatedRunDirectoryEnvironment() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = try MulticaMCPConfiguration.make(
            command: "/signed/askkey",
            args: ["mcp"],
            environment: [
                "ASKKEY_DEBUG_RUN_DIRECTORY": root.path,
                "ASKKEY_DEBUG_AUTHENTICATION": "allow",
            ],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let value = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )

        #if DEBUG
        XCTAssertEqual(value.keys.sorted(), ["args", "command", "env"])
        XCTAssertEqual(value["command"] as? String, "/signed/askkey")
        XCTAssertEqual(value["args"] as? [String], ["mcp"])
        XCTAssertEqual(
            (value["env"] as? [String: Any])?.keys.sorted(),
            ["ASKKEY_DEBUG_RUN_DIRECTORY"]
        )
        XCTAssertEqual(
            (value["env"] as? [String: Any])?["ASKKEY_DEBUG_RUN_DIRECTORY"] as? String,
            root.path
        )
        XCTAssertNil((value["env"] as? [String: Any])?["ASKKEY_DEBUG_AUTHENTICATION"])
        #else
        XCTAssertEqual(value.keys.sorted(), ["args", "command"])
        XCTAssertNil(value["env"])
        #endif
    }

    func testAppConfigurationDoesNotSilentlyOmitAnInvalidDebugRunDirectory() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-app-multica-missing-\(UUID().uuidString)", isDirectory: true)

        #if DEBUG
        XCTAssertThrowsError(try MulticaMCPConfiguration.make(
            command: "/signed/askkey",
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": missingRoot.path],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )) { error in
            XCTAssertEqual(error as? DebugRunDirectoryError, .invalidDirectory)
        }
        #else
        XCTAssertNoThrow(try MulticaMCPConfiguration.make(
            command: "/signed/askkey",
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": missingRoot.path],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
        #endif
    }

    private func makePrivateDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/askkey-app-multica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }
}
