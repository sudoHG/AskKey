import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

final class CursorConfigSafetyTests: CursorUserMCPAdapterTests {
    func testEmptyConfigWritesOnlyAskKeyServerForIDEAndCLI() throws {
        let harness = try makeHarness()
        let diff = try harness.adapter.preview()
        XCTAssertEqual(diff.before, "")
        XCTAssertTrue(diff.after.contains("askkey"))
        XCTAssertTrue(diff.after.contains(harness.helperURL.path))

        _ = try harness.adapter.apply()

        let json = try harness.userJSON()
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertEqual(Array(servers.keys), ["askkey"])
        let askkey = try XCTUnwrap(servers["askkey"] as? [String: Any])
        XCTAssertEqual(askkey["command"] as? String, harness.helperURL.path)
        XCTAssertEqual(askkey["args"] as? [String], ["mcp"])
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.cliSpecificURL.path))
        XCTAssertEqual(harness.adapter.userConfigURL, harness.userConfigURL)
    }
    func testMultipleServersKeepNonAskKeyEntriesAndRedactEnvInDiff() throws {
        let harness = try makeHarness()
        let existing = """
        {
          "mcpServers": {
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": { "GITHUB_TOKEN": "must-not-appear-in-diff" },
              "headers": { "X-API-Key": "header-secret" },
              "access_token": "access-secret",
              "clientSecret": "client-secret"
            },
            "askkey": { "command": "/old/askkey", "args": ["mcp"] }
          },
          "other": { "keep": true }
        }
        """
        try harness.writeUserConfig(existing, permissions: 0o644)

        let diff = try harness.adapter.preview()
        XCTAssertFalse(diff.before.contains("must-not-appear-in-diff"))
        XCTAssertFalse(diff.after.contains("must-not-appear-in-diff"))
        XCTAssertFalse(diff.before.contains("header-secret"))
        XCTAssertFalse(diff.before.contains("access-secret"))
        XCTAssertFalse(diff.before.contains("client-secret"))
        XCTAssertFalse(diff.after.contains("header-secret"))
        XCTAssertFalse(diff.after.contains("access-secret"))
        XCTAssertFalse(diff.after.contains("client-secret"))
        XCTAssertTrue(diff.before.contains("github"))
        XCTAssertTrue(diff.after.contains(harness.helperURL.path))

        _ = try harness.adapter.apply()

        let json = try harness.userJSON()
        XCTAssertEqual((json["other"] as? [String: Any])?["keep"] as? Bool, true)
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        XCTAssertEqual(Set(servers.keys), ["askkey", "github"])
        let github = try XCTUnwrap(servers["github"] as? [String: Any])
        XCTAssertEqual((github["env"] as? [String: Any])?["GITHUB_TOKEN"] as? String, "must-not-appear-in-diff")
        let askkey = try XCTUnwrap(servers["askkey"] as? [String: Any])
        XCTAssertEqual(askkey["command"] as? String, harness.helperURL.path)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o644)
        XCTAssertEqual(try Data(contentsOf: harness.projectConfigURL), Data(#"{ "mcpServers": { "project-only": {} } }"#.utf8))
    }
    func testInvalidJSONIsNotOverwritten() throws {
        let harness = try makeHarness()
        let invalid = Data("{ not json\n".utf8)
        try harness.writeUserConfig(invalid, permissions: 0o600)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CursorMCPError, .invalidJSON)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), invalid)
    }
    func testSymbolicLinkIsRejectedWithoutFollowing() throws {
        let harness = try makeHarness()
        let target = harness.root.appendingPathComponent("target.json")
        try Data("{}\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: harness.userConfigURL, withDestinationURL: target)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CursorMCPError, .unsafeFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("{}\n".utf8))
        var st = stat()
        XCTAssertEqual(lstat(harness.userConfigURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFLNK)
    }
    func testSpecialFileIsRejected() throws {
        let harness = try makeHarness()
        guard mkfifo(harness.userConfigURL.path, 0o600) == 0 else {
            return XCTFail("mkfifo failed")
        }
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CursorMCPError, .unsafeFile)
        }
        var st = stat()
        XCTAssertEqual(lstat(harness.userConfigURL.path, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFIFO)
    }
    func testProjectCursorConfigIsUnchanged() throws {
        let harness = try makeHarness()
        let before = try Data(contentsOf: harness.projectConfigURL)
        _ = try harness.adapter.apply()
        XCTAssertEqual(try Data(contentsOf: harness.projectConfigURL), before)
        XCTAssertFalse(harness.adapter.userConfigURL.path.contains("/project/"))
    }
    func testInterruptedReplaceRestoresOriginalBytesAndPermissions() throws {
        let harness = try makeHarness(replaceConfig: { _, _ in
            throw CursorMCPError.replaceFailed
        })
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o640)
        XCTAssertThrowsError(try harness.adapter.apply()) { error in
            XCTAssertEqual(error as? CursorMCPError, .replaceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), original)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
    func testApplySnapshotsPermissionsAfterTheAtomicMove() throws {
        var firstMove = true
        let harness = try makeHarness(moveConfigExclusively: { source, destination in
            if firstMove {
                firstMove = false
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o640],
                    ofItemAtPath: source.path
                )
            }
            let result = destination.path.withCString { destinationPath in
                source.path.withCString { sourcePath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw CursorMCPError.rollbackFailed }
        })
        try harness.writeUserConfig("{}", permissions: 0o600)

        _ = try harness.adapter.apply()

        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }
}
