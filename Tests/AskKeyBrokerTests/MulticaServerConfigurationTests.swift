import Foundation
import XCTest
@testable import AskKeyBroker

final class MulticaServerConfigurationTests: XCTestCase {
    func testDebugConfigurationSerializesOnlyTheIsolatedRunDirectoryEnvironment() throws {
        let root = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configuration = try MulticaServerConfiguration.make(
            command: "/signed/askkey",
            args: ["mcp"],
            environment: [
                "ASKKEY_DEBUG_RUN_DIRECTORY": root.path,
                "ASKKEY_DEBUG_AUTHENTICATION": "allow",
            ],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        let value = try XCTUnwrap(jsonObject(configuration))

        #if DEBUG
        XCTAssertEqual(value.keys.sorted(), ["args", "command", "env"])
        XCTAssertEqual(value["command"] as? String, "/signed/askkey")
        XCTAssertEqual(value["args"] as? [String], ["mcp"])
        XCTAssertEqual(
            (value["env"] as? [String: String])?.keys.sorted(),
            ["ASKKEY_DEBUG_RUN_DIRECTORY"]
        )
        XCTAssertEqual(
            (value["env"] as? [String: String])?["ASKKEY_DEBUG_RUN_DIRECTORY"],
            root.path
        )
        XCTAssertNil((value["env"] as? [String: String])?["ASKKEY_DEBUG_AUTHENTICATION"])
        #else
        XCTAssertEqual(value.keys.sorted(), ["args", "command"])
        XCTAssertNil(value["env"])
        #endif
    }

    func testInvalidDebugRunDirectoryIsNotSilentlyOmitted() throws {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-multica-missing-\(UUID().uuidString)", isDirectory: true)

        #if DEBUG
        XCTAssertThrowsError(try MulticaServerConfiguration.make(
            command: "/signed/askkey",
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": missingRoot.path],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )) { error in
            XCTAssertEqual(error as? DebugRunDirectoryError, .invalidDirectory)
        }
        #else
        XCTAssertNoThrow(try MulticaServerConfiguration.make(
            command: "/signed/askkey",
            environment: ["ASKKEY_DEBUG_RUN_DIRECTORY": missingRoot.path],
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ))
        #endif
    }

    func testRemovedMulticaConfigCommandFailsClosed() throws {
        let result = try runHelper(
            arguments: ["multica-config"],
            environment: [:]
        )
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("Usage:"))
        XCTAssertTrue(result.stdout.isEmpty)
    }

    private func jsonObject(_ configuration: MulticaServerConfiguration) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
    }

    private func makePrivateDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/askkey-multica-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func runHelper(
        arguments: [String],
        environment additions: [String: String]
    ) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(additions) { _, new in new }
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile(),
            error.fileHandleForReading.readDataToEndOfFile()
        )
    }

    private func helperExecutable() throws -> URL {
        let executable = Bundle(for: MulticaServerConfigurationTests.self)
            .bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}
