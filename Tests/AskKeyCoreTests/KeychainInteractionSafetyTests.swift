import Foundation
import Security
import XCTest
@testable import AskKeyCore

final class KeychainInteractionSafetyTests: XCTestCase {
    func testUntrustedKeychainQueriesAndProbeForbidAuthenticationUI() throws {
        XCTAssertFalse(KeychainQuery.systemKeychainAllowed)
        let query = KeychainQuery.forbidAuthenticationUI([:])
        XCTAssertEqual(
            query[kSecUseAuthenticationUI as String] as? String,
            kSecUseAuthenticationUIFail as String
        )

        let sourceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "keychain-probe",
                withExtension: "m",
                subdirectory: "Fixtures"
            )
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard source.contains("kSecUseAuthenticationUI"),
              source.contains("kSecUseAuthenticationUIFail") else {
            return XCTFail("probe query must fail before Security can show authentication UI")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyKeychainPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("keychain-probe")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "clang", sourceURL.path,
            "-framework", "Security",
            "-framework", "CoreFoundation",
            "-framework", "LocalAuthentication",
            "-o", executable.path,
        ]
        compiler.standardOutput = Pipe()
        compiler.standardError = Pipe()
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)

        XCTAssertEqual(try runProbe(executable, arguments: ["policy", "unused", "-"]).status, 0)

        let missingService = "com.sudohg.askkey.tests.missing.\(UUID().uuidString)"
        for name in ["askkey-old", "askkey-helper", "same-uid-probe"] {
            let copy = directory.appendingPathComponent(name)
            try FileManager.default.copyItem(at: executable, to: copy)
            let result = try runProbe(copy, arguments: ["read", missingService, "-"])
            XCTAssertFalse(result.timedOut, "\(name) waited for authentication UI")
            XCTAssertNotEqual(result.status, 0, "\(name) unexpectedly read a missing test service")
            XCTAssertEqual(result.output, Data())
        }
        let formalService = try runProbe(
            executable,
            arguments: ["read", VaultConfiguration.appKeychainService, "-"]
        )
        XCTAssertEqual(formalService.status, 67)
        XCTAssertFalse(formalService.timedOut)
    }

    func testTestSourcesCannotWriteOrDeleteKeychainItems() throws {
        let testsRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: testsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        )
        let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "h"]
        let forbiddenCalls = [
            ["SecItem", "Add"].joined(),
            ["SecItem", "Delete"].joined(),
            ["SecItem", "Update"].joined(),
            ["SecKeychain", "Create"].joined(),
            ["SecKeychain", "Delete"].joined(),
            ["SecKeychain", "AddGenericPassword"].joined(),
        ]
        let copyMatching = ["SecItem", "CopyMatching"].joined()
        for case let url as URL in enumerator where sourceExtensions.contains(url.pathExtension) {
            let source = try String(contentsOf: url, encoding: .utf8)
            for call in forbiddenCalls {
                XCTAssertFalse(hasCall(call, in: source), "\(url.lastPathComponent) must not call \(call)")
            }
            let copyCount = callCount(copyMatching, in: source)
            if url.lastPathComponent == "keychain-probe.m" {
                XCTAssertEqual(copyCount, 1, "policy-guarded probe keeps one read-only query")
            } else {
                XCTAssertEqual(copyCount, 0, "\(url.lastPathComponent) must not query Keychain")
            }
            if url.pathExtension == "swift" {
                if url.path != #filePath { XCTAssertFalse(source.contains("import Security")) }
                XCTAssertFalse(
                    containsPattern(
                        ["Keychain", "Store"].joined() + #"\s*\."#,
                        in: source
                    )
                )
                XCTAssertFalse(
                    containsPattern(
                        ["Vault", "shared"].joined(separator: #"\s*\.\s*"#)
                            + #"[\s\S]{0,120}?\.\s*unlock\s*\("#,
                        in: source
                    )
                )
            }
        }
    }

    private func runProbe(
        _ executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: Data, timedOut: Bool) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let timedOut = process.isRunning
        if timedOut { process.terminate() }
        process.waitUntilExit()
        return (
            process.terminationStatus,
            output.fileHandleForReading.readDataToEndOfFile(),
            timedOut
        )
    }

    private func hasCall(_ name: String, in source: String) -> Bool {
        callCount(name, in: source) > 0
    }

    private func callCount(_ name: String, in source: String) -> Int {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"\s*\("#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return expression.numberOfMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
    }

    private func containsPattern(_ pattern: String, in source: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ) != nil
    }
}
