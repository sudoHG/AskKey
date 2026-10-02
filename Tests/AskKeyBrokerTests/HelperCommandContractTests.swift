import XCTest
@testable import AskKeyBroker

final class HelperCommandContractTests: XCTestCase {
    func testRemovedDirectCommandsFailClosedWithUsage() throws {
        for command in [
            ["catalog"],
            ["multica-config"],
            ["write-request"],
            ["write-commit"],
            ["write-cancel"],
            ["request-status", "request-id", "capability"],
            ["request-cancel", "request-id", "capability"],
        ] {
            let result = try runHelper(arguments: command)
            XCTAssertNotEqual(result.status, 0, command.joined(separator: " "))
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            XCTAssertTrue(
                stderr.contains("Usage:"),
                "\(command.joined(separator: " ")) should fail closed as usage, got \(stderr)"
            )
            XCTAssertFalse(stderr.contains("SECRET"))
            XCTAssertTrue(result.stdout.isEmpty, command.joined(separator: " "))
        }
    }

    func testOpenOnUnpackagedHelperFailsClosedWithoutSecrets() throws {
        let result = try runHelper(arguments: ["open"])
        XCTAssertNotEqual(result.status, 0)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(stdout.isEmpty)
        XCTAssertFalse(stderr.contains("Usage:"))
        XCTAssertTrue(stderr.contains("Ask Key could not open the host application."))
        XCTAssertFalse(stderr.contains("SECRET"))
        XCTAssertFalse(stderr.contains("vault"))
        XCTAssertFalse(stderr.contains("Keychain"))
    }

    func testPublicHealthAndVersionStillForward() throws {
        for command in ["health", "version", "status"] {
            let result = try runHelper(arguments: [command])
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            XCTAssertFalse(stderr.contains("Usage:"), command)
            XCTAssertFalse(
                String(decoding: result.stdout, as: UTF8.self).contains("SECRET"),
                command
            )
        }
    }

    private func runHelper(arguments: [String]) throws -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = try helperExecutable()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["ASKKEY_BROKER_SOCKET": "/tmp/askkey-missing-\(UUID().uuidString).sock"]) { _, new in new }
        let output = Pipe()
        let error = Pipe()
        process.standardInput = FileHandle.nullDevice
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
        let executable = Bundle(for: HelperCommandContractTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }
}
