import Darwin
import Foundation
import XCTest
@testable import AskKeyIntegrations

final class CodexDiscoveryHookConfigurationTests: XCTestCase {
    func testPreviewAddsExpectedHookAndKeepsExistingHookOrder() throws {
        let harness = try Harness(json: """
        {
          "hooks": {
            "PreToolUse": [
              { "matcher": "before", "hooks": [{ "type": "command", "command": "/usr/bin/true" }] },
              { "matcher": "after", "hooks": [{ "type": "command", "command": "/usr/bin/false" }] }
            ],
            "PostToolUse": [
              { "matcher": "post", "hooks": [{ "type": "command", "command": "/usr/bin/true" }] }
            ]
          },
          "model": "keep"
        }
        """)
        let configuration = harness.configuration

        let plan = try configuration.preview()

        XCTAssertTrue(plan.changed)
        XCTAssertEqual(plan.before, harness.originalData)
        XCTAssertNotNil(plan.after)
        XCTAssertTrue(plan.summary.contains("Ask Key"))
        XCTAssertFalse(plan.redactedDescription.contains("/usr/bin/false"))
        XCTAssertEqual(try harness.readData(), harness.originalData)

        let afterData = try XCTUnwrap(plan.after)
        let after = try afterData.jsonObject()
        let root = try XCTUnwrap(after as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 3)
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "before")
        XCTAssertEqual(preToolUse[1]["matcher"] as? String, "after")
        XCTAssertEqual(
            try preToolUse[2].asJSONData(),
            try Self.expectedHookGroup.asJSONData()
        )
        let postToolUse = try XCTUnwrap(hooks["PostToolUse"] as? [[String: Any]])
        XCTAssertEqual(postToolUse.count, 1)
        XCTAssertEqual(postToolUse[0]["matcher"] as? String, "post")
        XCTAssertEqual(root["model"] as? String, "keep")
    }

    func testApplyUsesReviewedPlanAndASecondPreviewIsIdempotent() throws {
        let harness = try Harness(json: "{ \"hooks\": { \"PreToolUse\": [] } }\n")
        let configuration = harness.configuration
        let plan = try configuration.preview()

        try configuration.apply(plan: plan)

        XCTAssertEqual(try harness.readData(), plan.after)
        XCTAssertTrue(try configuration.hasExpectedHook())
        let second = try configuration.preview()
        XCTAssertFalse(second.changed)
        XCTAssertEqual(second.before, second.after)
        XCTAssertEqual(second.after, plan.after)
        let backups = try harness.backupFiles()
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try backup.readData(), harness.originalData)
    }

    func testExistingExpectedHookIsRecognizedWithoutChangingItsPosition() throws {
        let harness = try Harness(data: try Self.jsonData(
            root: [
                "hooks": [
                    "PreToolUse": [
                        ["matcher": "before", "hooks": [["type": "command", "command": "/usr/bin/true"]]],
                        Self.expectedHookGroup
                    ]
                ]
            ]
        ))
        let configuration = harness.configuration

        XCTAssertTrue(try configuration.hasExpectedHook())
        let plan = try configuration.preview()
        XCTAssertFalse(plan.changed)
        XCTAssertEqual(plan.before, harness.originalData)
        XCTAssertEqual(plan.after, harness.originalData)
        try configuration.apply(plan: plan)
        XCTAssertEqual(try harness.readData(), harness.originalData)
    }

    func testCustomMatchingHookFailsWithIndependentError() throws {
        let custom = Self.expectedHookGroup.merging(
            ["matcher": "custom"],
            uniquingKeysWith: { _, new in new }
        )
        let harness = try Harness(data: try Self.jsonData(
            root: ["hooks": ["PreToolUse": [custom]]]
        ))

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .customHookMismatch)
        }
    }

    func testMultipleMatchingHooksFailWithIndependentError() throws {
        let harness = try Harness(data: try Self.jsonData(
            root: ["hooks": ["PreToolUse": [Self.expectedHookGroup, Self.expectedHookGroup]]]
        ))

        XCTAssertThrowsError(try harness.configuration.hasExpectedHook()) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .multipleExpectedHooks)
        }
    }

    func testMissingHooksArrayIsCreatedAndOtherHookEventsArePreserved() throws {
        let harness = try Harness(json: """
        { "hooks": { "PostToolUse": [{ "matcher": "post", "hooks": [] }] }, "other": true }
        """)
        let plan = try harness.configuration.preview()
        try harness.configuration.apply(plan: plan)

        let root = try XCTUnwrap(try harness.readData().jsonObject() as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual((hooks["PostToolUse"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(root["other"] as? Bool, true)
    }

    func testUnsafeHooksSymlinkIsRejected() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let target = harness.root.appendingPathComponent("target.json")
        try harness.originalData.write(to: target)
        try FileManager.default.removeItem(at: harness.hooksURL)
        try FileManager.default.createSymbolicLink(at: harness.hooksURL, withDestinationURL: target)

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .unsafeHooksFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), harness.originalData)
    }

    func testPreviewAndApplyRejectUnsafeBackupDirectory() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let target = harness.root.appendingPathComponent("backup-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: harness.backupDirectory)
        try FileManager.default.createSymbolicLink(at: harness.backupDirectory, withDestinationURL: target)

        let plan = try harness.configuration.preview()
        XCTAssertThrowsError(try harness.configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .unsafeBackupDirectory)
        }
        XCTAssertEqual(try harness.readData(), harness.originalData)
    }

    func testExistingAncestorSymlinkRejectsHookPreviewAndApplyWithoutChangingTarget() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let target = harness.root.appendingPathComponent("hook-target", isDirectory: true)
        let existingChild = target.appendingPathComponent("existing-child", isDirectory: true)
        try FileManager.default.createDirectory(at: existingChild, withIntermediateDirectories: true)
        let targetHooks = existingChild.appendingPathComponent("hooks.json")
        try harness.originalData.write(to: targetHooks)
        let sentinel = existingChild.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("keep unrelated hook directory file\n".utf8)
        try sentinelData.write(to: sentinel)
        let alias = harness.root.appendingPathComponent("hook-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let directConfiguration = CodexDiscoveryHookConfiguration(
            hooksURL: targetHooks,
            backupDirectory: harness.backupDirectory
        )
        let plan = try directConfiguration.preview()
        XCTAssertTrue(plan.changed)
        let configuration = CodexDiscoveryHookConfiguration(
            hooksURL: alias.appendingPathComponent("existing-child/hooks.json"),
            backupDirectory: harness.backupDirectory
        )

        XCTAssertThrowsError(try configuration.preview()) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .unsafeHooksFile)
        }
        XCTAssertThrowsError(try configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .unsafeHooksFile)
        }
        XCTAssertEqual(try Data(contentsOf: targetHooks), harness.originalData)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existingChild.path).sorted(),
                       ["hooks.json", "sentinel.txt"])
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testExistingAncestorSymlinkRejectsBackupWithoutChangingHooksOrTarget() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let target = harness.root.appendingPathComponent("backup-target", isDirectory: true)
        let existingChild = target.appendingPathComponent("existing-child", isDirectory: true)
        try FileManager.default.createDirectory(at: existingChild, withIntermediateDirectories: true)
        let sentinel = existingChild.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("keep unrelated backup directory file\n".utf8)
        try sentinelData.write(to: sentinel)
        let alias = harness.root.appendingPathComponent("backup-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let configuration = CodexDiscoveryHookConfiguration(
            hooksURL: harness.hooksURL,
            backupDirectory: alias.appendingPathComponent("existing-child", isDirectory: true)
        )
        let plan = try configuration.preview()

        XCTAssertThrowsError(try configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .unsafeBackupDirectory)
        }
        XCTAssertEqual(try harness.readData(), harness.originalData)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existingChild.path), ["sentinel.txt"])
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testExistingNestedDirectoriesAllowHookApplyAndBackup() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let hooksDirectory = harness.root.appendingPathComponent("ordinary/home/.codex", isDirectory: true)
        let backupDirectory = harness.root.appendingPathComponent("ordinary/support/backups", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let hooksURL = hooksDirectory.appendingPathComponent("hooks.json")
        try harness.originalData.write(to: hooksURL)
        let configuration = CodexDiscoveryHookConfiguration(hooksURL: hooksURL, backupDirectory: backupDirectory)
        let plan = try configuration.preview()

        try configuration.apply(plan: plan)

        XCTAssertTrue(try configuration.hasExpectedHook())
        XCTAssertEqual(try Data(contentsOf: hooksURL), plan.after)
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), harness.originalData)
    }

    func testFirstInstallCreatesMissingHookAndBackupDirectoryChainSafely() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let hooksURL = harness.root
            .appendingPathComponent("new-codex-home", isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("hooks.json")
        let backupDirectory = harness.root
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("client-backups", isDirectory: true)
            .appendingPathComponent("codex-discovery", isDirectory: true)
        let configuration = CodexDiscoveryHookConfiguration(
            hooksURL: hooksURL,
            backupDirectory: backupDirectory
        )

        let plan = try configuration.preview()
        XCTAssertNil(plan.before)
        try configuration.apply(plan: plan)

        XCTAssertTrue(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectory.path))
        XCTAssertTrue(try configuration.hasExpectedHook())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        ).count, 1)
    }

    func testApplyRejectsConcurrentModificationBeforeWriting() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let plan = try harness.configuration.preview()
        let concurrent = Data("{ \"external\": true }\n".utf8)
        try concurrent.write(to: harness.hooksURL)

        XCTAssertThrowsError(try harness.configuration.apply(plan: plan)) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .concurrentModification)
        }
        XCTAssertEqual(try harness.readData(), concurrent)
        XCTAssertTrue(try harness.backupFiles().isEmpty)
    }

    func testRestoreReturnsToReviewedBeforeBytes() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let configuration = harness.configuration
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: harness.hooksURL.path
        )
        let plan = try configuration.preview()
        try configuration.apply(plan: plan)

        XCTAssertEqual(try harness.mode(), 0o640)
        try configuration.restore(plan: plan)

        XCTAssertEqual(try harness.readData(), harness.originalData)
        XCTAssertEqual(try harness.mode(), 0o640)
        XCTAssertFalse(try configuration.hasExpectedHook())
    }

    func testRestoreRefusesToOverwriteConcurrentChange() throws {
        let harness = try Harness(json: "{ \"hooks\": {} }\n")
        let configuration = harness.configuration
        let plan = try configuration.preview()
        try configuration.apply(plan: plan)
        let concurrent = Data("{ \"external\": true }\n".utf8)
        try concurrent.write(to: harness.hooksURL)

        XCTAssertThrowsError(try configuration.restore(plan: plan)) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .restoreConflict)
        }
        XCTAssertEqual(try harness.readData(), concurrent)
    }

    func testMissingFileCanBeCreatedAndRestoredAsMissing() throws {
        let harness = try Harness()
        let configuration = harness.configuration
        let plan = try configuration.preview()

        XCTAssertNil(plan.before)
        XCTAssertTrue(plan.changed)
        try configuration.apply(plan: plan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.hooksURL.path))

        try configuration.restore(plan: plan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.hooksURL.path))
    }

    func testInvalidJSONFailsClosedWithoutWriting() throws {
        let harness = try Harness(raw: "{ invalid\n")

        XCTAssertThrowsError(try harness.configuration.preview()) { error in
            XCTAssertEqual(error as? CodexDiscoveryHookConfigurationError, .invalidHooksFile)
        }
        XCTAssertEqual(try harness.readData(), harness.originalData)
    }
}

private extension CodexDiscoveryHookConfigurationTests {
    static let expectedHookGroup: [String: Any] = [
        "matcher": "^(Bash|mcp__askkey__list_credentials)$",
        "hooks": [[
            "type": "mcp_tool",
            "server": "askkey",
            "tool": "credential_discovery_guard",
            "input": [
                "session_id": "${session_id}",
                "turn_id": "${turn_id}",
                "tool_name": "${tool_name}",
                "tool_input": "${tool_input}"
            ],
            "timeout": 3
        ]]
    ]

    static func jsonData(root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

private final class Harness {
    let root: URL
    let hooksURL: URL
    let backupDirectory: URL
    let originalData: Data
    let configuration: CodexDiscoveryHookConfiguration

    convenience init(json: String) throws {
        try self.init(rawData: Data(json.utf8))
    }

    convenience init(data: Data) throws {
        try self.init(rawData: data)
    }

    convenience init() throws {
        try self.init(rawData: nil)
    }

    convenience init(raw: String) throws {
        try self.init(rawData: Data(raw.utf8))
    }

    private init(rawData: Data?) throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("askkey-hook-config-\(UUID().uuidString)", isDirectory: true)
        hooksURL = root.appendingPathComponent("hooks.json")
        backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        originalData = rawData ?? Data()

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        if let rawData {
            try rawData.write(to: hooksURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: hooksURL.path
            )
        }
        configuration = CodexDiscoveryHookConfiguration(
            hooksURL: hooksURL,
            backupDirectory: backupDirectory
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func readData() throws -> Data {
        try Data(contentsOf: hooksURL)
    }

    func mode() throws -> Int {
        var info = stat()
        guard lstat(hooksURL.path, &info) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Int(info.st_mode & 0o777)
    }

    func backupFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}

private extension Data {
    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: self)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func asJSONData() throws -> Data {
        try JSONSerialization.data(withJSONObject: self, options: [.sortedKeys])
    }
}

private extension URL {
    func readData() throws -> Data {
        try Data(contentsOf: self)
    }
}
