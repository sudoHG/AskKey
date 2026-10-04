import Darwin
import Foundation
import XCTest
@testable import AskKeyIntegrations

final class CommandDiscoveryHookConfigurationTests: XCTestCase {
    func testCursorPreviewMergesExpectedCommandsAndPreservesOtherHooks() throws {
        let harness = try Harness(
            format: .cursorMerged,
            existing: [
                "version": 1,
                "hooks": [
                    "preToolUse": [
                        ["command": "/usr/bin/other-before"],
                        ["command": "/usr/bin/other-after"]
                    ],
                    "postToolUse": [
                        ["command": "/usr/bin/after"]
                    ]
                ],
                "keep": "user setting"
            ]
        )

        let plan = try harness.configuration.preview()

        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.before, harness.originalData)
        XCTAssertNotNil(plan.after)
        XCTAssertTrue(plan.summary.contains("Ask Key"))
        XCTAssertFalse(plan.redactedDescription.contains("/usr/bin/other"))
        XCTAssertEqual(try harness.readData(), harness.originalData)

        let after = try XCTUnwrap(plan.after)
        let root = try XCTUnwrap(try after.jsonObject() as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertEqual(root["keep"] as? String, "user setting")
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["preToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 3)
        XCTAssertEqual(preToolUse[0]["command"] as? String, "/usr/bin/other-before")
        XCTAssertEqual(preToolUse[1]["command"] as? String, "/usr/bin/other-after")
        XCTAssertEqual(
            preToolUse[2]["command"] as? String,
            "'/signed/Ask Key.app/Contents/Resources/askkey' hook cursor"
        )
        let postToolUse = try XCTUnwrap(hooks["postToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.count, 2)
        XCTAssertEqual(postToolUse[0]["command"] as? String, "/usr/bin/after")
        XCTAssertEqual(
            postToolUse[1]["command"] as? String,
            "'/signed/Ask Key.app/Contents/Resources/askkey' hook cursor"
        )
    }

    func testCursorApplyCreatesBackupAndSecondPreviewIsIdempotent() throws {
        let harness = try Harness(format: .cursorMerged, existing: ["version": 1, "hooks": [:]])
        let plan = try harness.configuration.preview()
        try FileManager.default.createDirectory(
            at: harness.backupDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: harness.backupDirectory.path
        )

        try harness.configuration.apply(plan: plan)

        XCTAssertEqual(try harness.readData(), plan.after)
        XCTAssertTrue(try harness.configuration.hasExpectedHook())
        let second = try harness.configuration.preview()
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.before, second.after)
        XCTAssertEqual(second.after, plan.after)

        let backups = try harness.backupFiles()
        XCTAssertEqual(backups.count, 1)
        let backup: URL = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup), harness.originalData)
        XCTAssertEqual(try CommandDiscoveryHookConfigurationTests.mode(of: backup), 0o600)
        XCTAssertEqual(try CommandDiscoveryHookConfigurationTests.mode(of: harness.backupDirectory), 0o700)
    }

    func testCursorExistingExpectedHookDoesNotRewriteOrCreateBackup() throws {
        let expectedRoot = try XCTUnwrap(
            try Harness.expectedData(format: .cursorMerged).jsonObject() as? [String: Any]
        )
        let harness = try Harness(format: .cursorMerged, existing: expectedRoot)

        XCTAssertTrue(try harness.configuration.hasExpectedHook())
        let before = try harness.readData()
        let plan = try harness.configuration.preview()
        XCTAssertFalse(plan.changed)
        XCTAssertEqual(plan.before, before)
        XCTAssertEqual(plan.after, before)
        try harness.configuration.apply(plan: plan)
        XCTAssertEqual(try harness.readData(), before)
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testCursorCustomizedAskKeyCommandIsRejected() throws {
        let custom: [String: Any] = [
            "version": 1,
            "hooks": [
                "preToolUse": [[
                    "command": "/tmp/askkey hook cursor"
                ]]
            ]
        ]
        let harness = try Harness(format: .cursorMerged, existing: custom)

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .customHookMismatch)
        }
        XCTAssertEqual(try harness.readData(), harness.originalData)
    }

    func testCursorDuplicateExpectedCommandsAreRejected() throws {
        let expectedGroup: [String: Any] = [
            "command": "'/signed/Ask Key.app/Contents/Resources/askkey' hook cursor",
            "timeout": 3,
            "matcher": "Shell|MCP:.*"
        ]
        let duplicate: [String: Any] = [
            "version": 1,
            "hooks": [
                "preToolUse": [expectedGroup, expectedGroup]
            ]
        ]
        let harness = try Harness(format: .cursorMerged, existing: duplicate)

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .multipleExpectedHooks)
        }
    }

    func testGrokOwnedFileIsCreatedFromExpectedDataAndIsIdempotent() throws {
        let harness = try Harness(format: .grokOwned)
        let plan = try harness.configuration.preview()

        XCTAssertTrue(plan.changed)
        XCTAssertNil(plan.before)
        try harness.configuration.apply(plan: plan)

        XCTAssertEqual(try harness.readData(), plan.after)
        XCTAssertTrue(try harness.configuration.hasExpectedHook())
        let second = try harness.configuration.preview()
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.before, second.after)
        XCTAssertEqual(try harness.backupFiles().count, 1)
    }

    func testGrokOwnedUnknownFileIsRejectedWithoutOverwrite() throws {
        let harness = try Harness(
            format: .grokOwned,
            existing: ["version": 1, "hooks": ["beforeAgentResponse": [["command": "/usr/bin/user"]]]]
        )
        let original = try harness.readData()

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .ownedFileConflict)
        }
        XCTAssertEqual(try harness.readData(), original)
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testSymlinkIsRejectedAndConcurrentModificationIsPreserved() throws {
        let symlinkHarness = try Harness(format: .cursorMerged)
        let target = symlinkHarness.root.appendingPathComponent("target.json")
        try FileManager.default.createDirectory(
            at: symlinkHarness.hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlinkHarness.hooksURL,
            withDestinationURL: target
        )
        XCTAssertThrowsError(try symlinkHarness.configuration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .unsafeHooksFile)
        }

        let directorySymlinkHarness = try Harness(format: .cursorMerged)
        let directoryTarget = directorySymlinkHarness.root.appendingPathComponent("cursor-target", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: directorySymlinkHarness.hooksURL.deletingLastPathComponent().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: directorySymlinkHarness.hooksURL.deletingLastPathComponent(),
            withDestinationURL: directoryTarget
        )
        XCTAssertThrowsError(try directorySymlinkHarness.configuration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .unsafeHooksFile)
        }

        let concurrentHarness = try Harness(
            format: .cursorMerged,
            existing: ["version": 1, "hooks": [:]]
        )
        let plan = try concurrentHarness.configuration.preview()
        let concurrent = Data(#"{"version":1,"hooks":{"user":[{"command":"/usr/bin/new"}]}}"#.utf8)
        try concurrent.write(to: concurrentHarness.hooksURL)

        XCTAssertThrowsError(try concurrentHarness.configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .concurrentModification)
        }
        XCTAssertEqual(try concurrentHarness.readData(), concurrent)
        XCTAssertTrue(try concurrentHarness.backupFiles().isEmpty)

        let modeHarness = try Harness(
            format: .cursorMerged,
            existing: ["version": 1, "hooks": [:]]
        )
        let modePlan = try modeHarness.configuration.preview()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: modeHarness.hooksURL.path
        )
        XCTAssertThrowsError(try modeHarness.configuration.apply(plan: modePlan)) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .concurrentModification)
        }
        XCTAssertEqual(try modeHarness.readData(), modeHarness.originalData)
    }

    func testMissingHookCreatedByAnotherWriterIsPreserved() throws {
        let harness = try Harness(format: .cursorMerged)
        let plan = try harness.configuration.preview()
        let concurrent = Data(#"{"version":1,"hooks":{"user":[{"command":"/usr/bin/new"}]}}"#.utf8)
        try FileManager.default.createDirectory(
            at: harness.hooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try concurrent.write(to: harness.hooksURL)

        XCTAssertThrowsError(try harness.configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .concurrentModification)
        }
        XCTAssertEqual(try harness.readData(), concurrent)
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testExistingAncestorSymlinkIsRejectedForHooksAndBackupDirectories() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AskKeyCommandHook-Ancestor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real", isDirectory: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("home/.cursor", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: real.appendingPathComponent("support/backups", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)

        let hooksThroughAlias = alias.appendingPathComponent("home/.cursor/hooks.json")
        let hookConfiguration = CommandDiscoveryHookConfiguration(
            hooksURL: hooksThroughAlias,
            backupDirectory: root.appendingPathComponent("safe-backups"),
            expectedHooks: try Harness.expectedData(format: .cursorMerged),
            format: .cursorMerged
        )
        XCTAssertThrowsError(try hookConfiguration.preview()) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .unsafeHooksFile)
        }

        let safeHooksURL = root.appendingPathComponent("safe-home/.cursor/hooks.json")
        try FileManager.default.createDirectory(
            at: safeHooksURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data(#"{"version":1,"hooks":{}}"#.utf8)
        try original.write(to: safeHooksURL)
        let backupThroughAlias = alias.appendingPathComponent("support/backups")
        let backupConfiguration = CommandDiscoveryHookConfiguration(
            hooksURL: safeHooksURL,
            backupDirectory: backupThroughAlias,
            expectedHooks: try Harness.expectedData(format: .cursorMerged),
            format: .cursorMerged
        )
        let plan = try backupConfiguration.preview()
        XCTAssertThrowsError(try backupConfiguration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .unsafeBackupDirectory)
        }
        XCTAssertEqual(try Data(contentsOf: safeHooksURL), original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: real.appendingPathComponent("support/backups"), includingPropertiesForKeys: nil).isEmpty)
    }

    func testBackupDirectorySymlinkIsRejectedWithoutChangingHooks() throws {
        let harness = try Harness(
            format: .cursorMerged,
            existing: ["version": 1, "hooks": [:]]
        )
        let plan = try harness.configuration.preview()
        let support = harness.backupDirectory.deletingLastPathComponent()
        let target = harness.root.appendingPathComponent("backup-target", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: harness.backupDirectory,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try harness.configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CommandDiscoveryHookConfigurationError, .unsafeBackupDirectory)
        }
        XCTAssertEqual(try harness.readData(), harness.originalData)
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testMissingParentsAndNestedBackupDirectoryAreCreatedSafely() throws {
        let root = try CommandDiscoveryHookConfigurationTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooksURL = root.appendingPathComponent("home/.cursor/hooks.json")
        let backupDirectory = root.appendingPathComponent("support/client-backups/cursor")
        let expected = try Harness.expectedData(format: .cursorMerged)
        let configuration = CommandDiscoveryHookConfiguration(
            hooksURL: hooksURL,
            backupDirectory: backupDirectory,
            expectedHooks: expected,
            format: .cursorMerged
        )
        let plan = try configuration.preview()

        try configuration.apply(plan: plan)

        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectory.path))
        XCTAssertEqual(try CommandDiscoveryHookConfigurationTests.mode(of: backupDirectory), 0o700)
        XCTAssertTrue(try configuration.hasExpectedHook())
    }
}

private extension CommandDiscoveryHookConfigurationTests {
    final class Harness {
        let root: URL
        let hooksURL: URL
        let backupDirectory: URL
        let configuration: CommandDiscoveryHookConfiguration
        let originalData: Data

        init(
            format: CommandDiscoveryHookFormat,
            existing: [String: Any]? = nil
        ) throws {
            root = try CommandDiscoveryHookConfigurationTests.makeRoot()
            hooksURL = root.appendingPathComponent(
                format == .cursorMerged ? "home/.cursor/hooks.json" : "home/.grok/hooks/askkey-discovery.json"
            )
            backupDirectory = root.appendingPathComponent("support/backups")
            let expected = try Self.expectedData(format: format)
            configuration = CommandDiscoveryHookConfiguration(
                hooksURL: hooksURL,
                backupDirectory: backupDirectory,
                expectedHooks: expected,
                format: format
            )
            if let existing {
                try FileManager.default.createDirectory(
                    at: hooksURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                originalData = try Self.jsonData(existing)
                try originalData.write(to: hooksURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o600)],
                    ofItemAtPath: hooksURL.path
                )
            } else {
                originalData = Data()
            }
        }

        func readData() throws -> Data {
            try Data(contentsOf: hooksURL)
        }

        func backupFiles() throws -> [URL] {
            var info = stat()
            let result = backupDirectory.path.withCString { lstat($0, &info) }
            if result != 0 {
                guard errno == ENOENT else { throw POSIXError(.EIO) }
                return []
            }
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
            return try FileManager.default.contentsOfDirectory(
                at: backupDirectory,
                includingPropertiesForKeys: nil
            ).filter { !$0.lastPathComponent.hasPrefix(".") }
        }

        static func expectedData(format: CommandDiscoveryHookFormat) throws -> Data {
            switch format {
            case .claudeMerged:
                return try CommandDiscoveryClient.claude.definition(
                    helper: URL(fileURLWithPath: "/signed/Ask Key.app/Contents/Resources/askkey")
                )
            case .cursorMerged:
                let handler: [String: Any] = [
                    "command": "'/signed/Ask Key.app/Contents/Resources/askkey' hook cursor",
                    "timeout": 3,
                    "matcher": "Shell|MCP:.*"
                ]
                return try jsonData([
                    "version": 1,
                    "hooks": [
                        "preToolUse": [handler],
                        "postToolUse": [handler],
                        "postToolUseFailure": [handler]
                    ]
                ])
            case .grokOwned:
                let commandHandler: [String: Any] = [
                    "type": "command",
                    "command": "'/signed/Ask Key.app/Contents/Resources/askkey' hook grok",
                    "timeout": 3
                ]
                let toolHandler: [String: Any] = [
                    "matcher": "^(run_terminal_command|askkey__list_credentials)$",
                    "hooks": [commandHandler]
                ]
                return try jsonData([
                    "hooks": [
                        "UserPromptSubmit": [["hooks": [commandHandler]]],
                        "PreToolUse": [toolHandler],
                        "PostToolUse": [toolHandler],
                        "PostToolUseFailure": [toolHandler]
                    ]
                ])
            }
        }

        private static func jsonData(_ value: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        }
    }

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AskKeyCommandHook-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func mode(of url: URL) throws -> UInt16 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_mode & 0o777
    }
}

private extension Data {
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: self, options: [.fragmentsAllowed])
    }
}
