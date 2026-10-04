import Darwin
import Foundation
import XCTest
@testable import AskKeyIntegrations

final class ClaudeDiscoveryHookConfigurationTests: XCTestCase {
    // Synthetic settings model several independent tools sharing events,
    // groups and handler arrays, plus settings unrelated to hooks.
    private let multiToolSettings = #"""
    {
      "env": {"Z_SYNTHETIC":"value", "A_SYNTHETIC":"escaped \"string\""},
      "hooks": {
        "SessionStart": [{"matcher":"startup|resume","hooks":[{"type":"command","command":"synthetic-session"}]}],
        "PreToolUse": [
          {"matcher":"Write|Edit","hooks":[{"type":"command","command":"synthetic-format"},{"type":"prompt","prompt":"synthetic policy"}]},
          {"matcher":"Bash","hooks":[{"type":"command","command":"synthetic-shell-a"},{"type":"command","command":"synthetic-shell-b"}]}
        ],
        "UserPromptSubmit": [{"hooks":[{"type":"command","command":"synthetic-context","timeout":5}]}],
        "PostToolUse": [{"matcher":".*","hooks":[{"type":"command","command":"synthetic-audit","async":true}]}],
        "PostToolUseFailure": [{"matcher":"Bash","hooks":[{"type":"command","command":"synthetic-failure"}]}],
        "Stop": [{"hooks":[{"type":"command","command":"synthetic-stop"}]}],
        "Notification": [{"matcher":"permission_prompt","hooks":[{"type":"command","command":"synthetic-notify"}]}],
        "SubagentStop": [{"hooks":[{"type":"command","command":"synthetic-subagent"}]}],
        "PreCompact": [{"matcher":"auto","hooks":[{"type":"command","command":"synthetic-compact"}]}]
      },
      "permissions": {"deny":["Read(synthetic-secret)"],"allow":["Bash(synthetic-safe)"]},
      "enabledPlugins": {"synthetic-plugin":true},
      "model": "synthetic-model"
    }
    """#

    func testDefinitionAndMissingFileInstallReadBackAndReapply() throws {
        let fixture = try Fixture()
        XCTAssertEqual(CommandDiscoveryClient.claude.hooksURL(home: fixture.root), fixture.root.appendingPathComponent(".claude/settings.json"))
        XCTAssertEqual(CommandDiscoveryClient.claude.format, .claudeMerged)
        XCTAssertFalse(try fixture.configuration.hasExpectedHook())
        let definition = try fixture.definitionObject()
        let hooks = try XCTUnwrap(definition["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"]))
        for (event, groups) in hooks {
            XCTAssertEqual(groups.count, 1)
            XCTAssertEqual(groups[0]["matcher"] as? String, event == "UserPromptSubmit" ? nil : "Bash|mcp__askkey__list_credentials")
            let handler = try XCTUnwrap((groups[0]["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(handler["type"] as? String, "command")
            XCTAssertEqual(handler["command"] as? String, "'/synthetic/Ask Key.app/Contents/Helpers/askkey' hook claude")
        }
        try fixture.install()
        XCTAssertTrue(try fixture.configuration.hasExpectedHook())
        XCTAssertEqual(try fixture.mode(fixture.settings), 0o600)
        XCTAssertEqual(try fixture.mode(fixture.settings.deletingLastPathComponent()), 0o700)
        let before = try fixture.bytes()
        let plan = try fixture.configuration.preview()
        XCTAssertFalse(plan.changed)
        try fixture.configuration.apply(plan: plan)
        XCTAssertEqual(try fixture.bytes(), before)
        XCTAssertEqual(try fixture.backups().count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(fixture.backups().first)), Data())
    }

    func testMultiToolSettingsPreserveContentOrderModeAndPrivateBackup() throws {
        let original = Data(multiToolSettings.utf8)
        let fixture = try Fixture(bytes: original, mode: 0o640)
        let before = try fixture.object()
        try fixture.install()
        let after = try fixture.object()
        for key in before.keys where key != "hooks" { XCTAssertEqual(before[key] as? NSObject, after[key] as? NSObject) }
        let beforeHooks = try XCTUnwrap(before["hooks"] as? [String: [[String: Any]]])
        let afterHooks = try XCTUnwrap(after["hooks"] as? [String: [[String: Any]]])
        for (event, groups) in beforeHooks {
            XCTAssertEqual(Array(afterHooks[event]!.prefix(groups.count)) as NSArray, groups as NSArray)
            XCTAssertEqual(afterHooks[event]!.count, groups.count + (fixture.ownedEvents.contains(event) ? 1 : 0))
        }
        let output = try XCTUnwrap(String(data: fixture.bytes(), encoding: .utf8))
        try assertKeyOrder(["env", "hooks", "permissions", "enabledPlugins", "model"], in: output)
        try assertKeyOrder(["SessionStart", "PreToolUse", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure", "Stop", "Notification", "SubagentStop", "PreCompact"], in: output)
        XCTAssertTrue(output.contains(#"{"Z_SYNTHETIC":"value", "A_SYNTHETIC":"escaped \"string\""}"#))
        XCTAssertEqual(try fixture.mode(fixture.settings), 0o640)
        let backup = try XCTUnwrap(fixture.backups().first)
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try fixture.mode(backup), 0o600)
        XCTAssertEqual(try fixture.mode(fixture.backupDirectory), 0o700)
        try fixture.configuration.removeClaudeHooks()
        XCTAssertEqual(try fixture.object() as NSDictionary, before as NSDictionary)
        XCTAssertEqual(try fixture.mode(fixture.settings), 0o640)
    }

    func testSharedMatcherGroupRemovesOnlyOwnedHandler() throws {
        let fixture = try Fixture()
        var document = try fixture.definitionObject()
        var hooks = try XCTUnwrap(document["hooks"] as? [String: [[String: Any]]])
        let other: [String: Any] = ["type": "command", "command": "synthetic-other-tool", "timeout": 7]
        for event in fixture.ownedEvents {
            var group = hooks[event]![0]
            let owned = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
            group["hooks"] = [other, owned, other]
            hooks[event] = [group]
        }
        document["hooks"] = hooks
        document["permissions"] = ["deny": ["synthetic"]]
        try fixture.write(document)
        XCTAssertTrue(try fixture.configuration.hasExpectedHook())
        XCTAssertFalse(try fixture.configuration.preview().changed)
        try fixture.configuration.removeClaudeHooks()
        let removed = try fixture.object()
        let remaining = try XCTUnwrap(removed["hooks"] as? [String: [[String: Any]]])
        for event in fixture.ownedEvents {
            XCTAssertEqual(remaining[event]!.count, 1)
            XCTAssertEqual(remaining[event]![0]["hooks"] as? NSArray, [other, other] as NSArray)
        }
        XCTAssertEqual(removed["permissions"] as? NSDictionary, document["permissions"] as? NSDictionary)
        let before = try fixture.bytes(), backupCount = try fixture.backups().count
        try fixture.configuration.removeClaudeHooks()
        XCTAssertEqual(try fixture.bytes(), before)
        XCTAssertEqual(try fixture.backups().count, backupCount)
    }

    func testRemovalMissingFileDoesNotCreateSettingsOrBackup() throws {
        let fixture = try Fixture()
        try fixture.configuration.removeClaudeHooks()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settings.path))
        XCTAssertTrue(try fixture.backups().isEmpty)
    }

    func testEscapedKeysUnicodeAndNestedValuesSurviveInstallAndRemoval() throws {
        let raw = #"{"quoted\"key":1e+3,"line\nkey":-0.5,"unicode\u4e2d":true,"nested":{"array":[null,false,{"value":"\\\"escaped"}],"empty":[]},"hooks":{}}"#
        let fixture = try Fixture(bytes: Data(raw.utf8))
        let original = try fixture.object()
        try fixture.install()
        let installed = try fixture.object()
        for key in original.keys where key != "hooks" {
            XCTAssertEqual(installed[key] as? NSObject, original[key] as? NSObject)
        }
        XCTAssertTrue(try XCTUnwrap(String(data: fixture.bytes(), encoding: .utf8)).contains("1e+3"))
        try fixture.configuration.removeClaudeHooks()
        var removed = try fixture.object()
        removed["hooks"] = [:] as [String: Any]
        XCTAssertEqual(removed as NSDictionary, original as NSDictionary)
    }

    func testOversizedFileAndExpandedDocumentAreRejectedBeforeWriting() throws {
        let maximum = CommandDiscoveryHookConfiguration.maximumHooksBytes
        for size in [maximum - 20, maximum + 20] {
            let raw = Data(("{\"synthetic\":\"" + String(repeating: "x", count: size) + "\"}").utf8)
            let fixture = try Fixture(bytes: raw)
            XCTAssertThrowsError(try fixture.configuration.preview()) {
                XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .fileTooLarge)
            }
            XCTAssertEqual(try fixture.bytes(), raw)
            XCTAssertTrue(try fixture.backups().isEmpty)
        }
    }

    func testPartialInstallationAddsOnlyMissingEvents() throws {
        let fixture = try Fixture()
        var document = try fixture.definitionObject()
        var hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        hooks.removeValue(forKey: "PostToolUseFailure")
        document["hooks"] = hooks
        try fixture.write(document)
        XCTAssertFalse(try fixture.configuration.hasExpectedHook())
        try fixture.install()
        XCTAssertEqual(try fixture.object() as NSDictionary, try fixture.definitionObject() as NSDictionary)
    }

    func testCustomizedOwnedHandlersAndMatchersAreReportedWithoutWrites() throws {
        for customization in ["extraHandlerKey", "command", "selector", "timeout", "matcher", "wrongEvent"] {
            let fixture = try Fixture()
            var document = try fixture.definitionObject()
            var hooks = try XCTUnwrap(document["hooks"] as? [String: [[String: Any]]])
            var group = hooks["PreToolUse"]![0]
            var handler = try XCTUnwrap((group["hooks"] as? [[String: Any]])?.first)
            switch customization {
            case "extraHandlerKey": handler["async"] = true
            case "command": handler["command"] = "/synthetic/other/askkey hook claude --custom"
            case "selector": handler["command"] = "/synthetic/askkey hook unknown-client"
            case "timeout": handler["timeout"] = 99
            case "matcher": group["matcher"] = "Bash"
            default: break
            }
            group["hooks"] = [handler]
            if customization == "wrongEvent" {
                hooks.removeValue(forKey: "PreToolUse"); hooks["Stop"] = [group]
            } else { hooks["PreToolUse"] = [group] }
            document["hooks"] = hooks
            try fixture.write(document)
            let original = try fixture.bytes()
            for operation in [fixture.configuration.preview, { _ = try fixture.configuration.removeClaudeHooks(); return try fixture.configuration.preview() }] {
                XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .customHookMismatch) }
            }
            XCTAssertThrowsError(try fixture.configuration.hasExpectedHook())
            XCTAssertEqual(try fixture.bytes(), original)
            XCTAssertTrue(try fixture.backups().isEmpty)
        }
    }

    func testDuplicateOwnedHandlersAreReported() throws {
        let fixture = try Fixture()
        var document = try fixture.definitionObject()
        var hooks = try XCTUnwrap(document["hooks"] as? [String: [[String: Any]]])
        hooks["PreToolUse"]!.append(hooks["PreToolUse"]![0])
        document["hooks"] = hooks
        try fixture.write(document)
        XCTAssertThrowsError(try fixture.configuration.preview()) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .multipleExpectedHooks) }
        XCTAssertThrowsError(try fixture.configuration.removeClaudeHooks())
        XCTAssertTrue(try fixture.backups().isEmpty)
    }

    func testInvalidJSONAndHookShapesPreserveOriginalFile() throws {
        for raw in ["{", "[]", "null", #"{"hooks":null}"#, #"{"hooks":{"PreToolUse":{}}}"#,
                    #"{"hooks":{"PreToolUse":[{"hooks":false}]}}"#, #"{"env":1,"env":2}"#] {
            let fixture = try Fixture(bytes: Data(raw.utf8))
            XCTAssertThrowsError(try fixture.configuration.preview())
            XCTAssertThrowsError(try fixture.configuration.removeClaudeHooks())
            XCTAssertEqual(try fixture.bytes(), Data(raw.utf8))
            XCTAssertTrue(try fixture.backups().isEmpty)
        }
    }

    func testSymlinkSettingsParentAncestorAndBackupAreRejected() throws {
        for location in ["file", "parent", "ancestor", "backup"] {
            let fixture = try Fixture()
            let target = fixture.root.appendingPathComponent("target")
            if location == "file" {
                try fixture.createParent()
                try Data("{}".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: fixture.settings, withDestinationURL: target)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let link: URL
                switch location {
                case "parent": link = fixture.settings.deletingLastPathComponent()
                case "ancestor": link = fixture.root.appendingPathComponent("home")
                default: link = fixture.backupDirectory
                }
                try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            }
            if location == "backup" {
                let plan = try fixture.configuration.preview()
                XCTAssertThrowsError(try fixture.configuration.apply(plan: plan)) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .unsafeBackupDirectory) }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.settings.path))
            } else {
                XCTAssertThrowsError(try fixture.configuration.preview()) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .unsafeHooksFile) }
            }
        }
    }

    func testUnsafePermissionsAndHardlinksAreRejected() throws {
        for mode in [0o000, 0o622, 0o666] {
            let fixture = try Fixture(bytes: Data("{}".utf8), mode: mode)
            XCTAssertThrowsError(try fixture.configuration.preview()) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .unsafeHooksFile) }
        }
        let directory = try Fixture(bytes: Data("{}".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.settings.deletingLastPathComponent().path)
        XCTAssertThrowsError(try directory.configuration.preview())
        let hardlink = try Fixture(bytes: Data("{}".utf8))
        try FileManager.default.linkItem(at: hardlink.settings, to: hardlink.root.appendingPathComponent("alias.json"))
        XCTAssertThrowsError(try hardlink.configuration.preview())
    }

    func testConcurrentContentsAndModeChangesArePreserved() throws {
        for change in ["bytes", "mode", "created"] {
            let fixture = try Fixture(bytes: change == "created" ? nil : Data("{}".utf8))
            let plan = try fixture.configuration.preview()
            if change == "mode" {
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.settings.path)
            } else {
                try fixture.createParent()
                try Data(#"{"syntheticConcurrent":true}"#.utf8).write(to: fixture.settings)
            }
            let before = try fixture.bytes()
            XCTAssertThrowsError(try fixture.configuration.apply(plan: plan)) { XCTAssertEqual($0 as? CommandDiscoveryHookConfigurationError, .concurrentModification) }
            XCTAssertEqual(try fixture.bytes(), before)
            XCTAssertTrue(try fixture.backups().isEmpty)
        }
    }

    private func assertKeyOrder(_ keys: [String], in text: String) throws {
        var previous = text.startIndex
        for key in keys {
            let range = try XCTUnwrap(text.range(of: "\"\(key)\"", range: previous..<text.endIndex))
            previous = range.upperBound
        }
    }

    private final class Fixture {
        let root: URL
        let settings: URL
        let backupDirectory: URL
        let configuration: CommandDiscoveryHookConfiguration
        let helper = URL(fileURLWithPath: "/synthetic/Ask Key.app/Contents/Helpers/askkey")
        let ownedEvents = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"]
        init(bytes: Data? = nil, mode: Int = 0o600) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AskKeyClaudeSettings-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            settings = root.appendingPathComponent("home/.claude/settings.json")
            backupDirectory = root.appendingPathComponent("support/backups")
            configuration = try CommandDiscoveryClient.claude.configuration(
                home: root.appendingPathComponent("home"), helper: helper, backupDirectory: backupDirectory)
            if let bytes {
                try createParent()
                try bytes.write(to: settings)
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func createParent() throws { try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true) }
        func bytes() throws -> Data { try Data(contentsOf: settings) }
        func object() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: bytes()) as? [String: Any]) }
        func definitionObject() throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: CommandDiscoveryClient.claude.definition(helper: helper)) as? [String: Any]) }
        func write(_ object: [String: Any]) throws {
            try createParent()
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: settings)
        }
        func install() throws { try configuration.apply(plan: configuration.preview()) }
        func mode(_ url: URL) throws -> UInt16 {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.EIO) }
            return info.st_mode & 0o777
        }
        func backups() throws -> [URL] {
            guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }
    }
}
