import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations

final class CursorUserMCPAdapterTests: AskKeyCoreTestCase {
    private func makeHarness(
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil,
        helperURL: URL? = nil
    ) throws -> Harness {
        let harness = try Harness(
            replaceConfig: replaceConfig,
            removeConfig: removeConfig,
            moveConfigExclusively: moveConfigExclusively,
            removeBackupItem: removeBackupItem,
            helperURL: helperURL
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: harness.root) }
        return harness
    }

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

    func testBackupIsOwnerOnlySingleCopyAndRemovedAfterSuccessfulConnection() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o644)
        _ = try harness.adapter.apply()

        XCTAssertEqual(try harness.permissions(harness.backupDirectory), 0o700)
        XCTAssertEqual(try harness.permissions(harness.backupURL), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: harness.backupDirectory.path),
            [harness.backupURL.lastPathComponent]
        )

        try harness.withBroker { _ in
            let status = try harness.adapter.verify()
            XCTAssertTrue(status.connected)
            XCTAssertTrue(status.configReady)
            XCTAssertTrue(status.helperReady)
            XCTAssertTrue(status.protocolReady)
            XCTAssertTrue(status.brokerHealthy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    func testCleanupFailureThenUserEditUsesTheNewConfigAsRetryBaseline() throws {
        var cleanupFails = true
        let harness = try makeHarness(removeBackupItem: { url in
            if cleanupFails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        _ = try harness.adapter.apply()

        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify()) { error in
                XCTAssertEqual(error as? CursorMCPError, .backupCleanupFailed)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))

        let userEdit = Data(#"{"mcpServers":{"user-edit":{"command":"true"}}}"#.utf8)
        try harness.writeUserConfig(userEdit, permissions: 0o640)
        cleanupFails = false
        _ = try harness.adapter.apply()
        XCTAssertFalse(try harness.adapter.verify().connected)
        try harness.adapter.rollback()

        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), userEdit)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }

    func testConnectedConfigWithoutAManagedBackupStillVerifies() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try FileManager.default.removeItem(at: harness.backupURL)

        try harness.withBroker { _ in
            XCTAssertTrue(try harness.adapter.verify().connected)
        }
    }

    func testCleanupFailureThenPermissionEditUsesTheNewModeAsRetryBaseline() throws {
        var cleanupFails = true
        let harness = try makeHarness(removeBackupItem: { url in
            if cleanupFails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.removeItem(at: url)
        })
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify())
        }
        let beforeRetry = try Data(contentsOf: harness.userConfigURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: harness.userConfigURL.path
        )
        cleanupFails = false

        _ = try harness.adapter.apply()
        XCTAssertFalse(try harness.adapter.verify().connected)
        try harness.adapter.rollback()

        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), beforeRetry)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }

    func testOneAdapterCannotDeleteAnotherAdaptersBackupGeneration() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try harness.writeUserConfig(
            #"{"mcpServers":{"user-edit":{"command":"true"}}}"#,
            permissions: 0o640
        )
        let second = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.helperURL,
            brokerSocketPath: harness.socketPath,
            signing: .development
        )
        _ = try second.apply()

        try harness.withBroker { _ in
            XCTAssertThrowsError(try harness.adapter.verify()) { error in
                XCTAssertEqual(error as? CursorMCPError, .backupCleanupFailed)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
            XCTAssertTrue(try second.verify().connected)
        }
    }

    func testRollbackRestoresOriginalBytesAndPermissions() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o640)
        _ = try harness.adapter.apply()
        XCTAssertNotEqual(try Data(contentsOf: harness.userConfigURL), original)
        try harness.adapter.rollback()
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), original)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }

    func testRollbackPreservesAnExistingEmptyConfigFile() throws {
        let harness = try makeHarness()
        try harness.writeUserConfig(Data(), permissions: 0o640)

        _ = try harness.adapter.apply()
        try harness.adapter.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), Data())
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o640)
    }

    func testRollbackRemovesConfigOnlyWhenItDidNotExistBeforeApply() throws {
        let harness = try makeHarness()

        _ = try harness.adapter.apply()
        try harness.adapter.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }

    func testExternalDeleteAfterApplyIsNotRecreatedByRollback() throws {
        let harness = try makeHarness()
        try harness.writeUserConfig("{}", permissions: 0o640)
        _ = try harness.adapter.apply()
        try FileManager.default.removeItem(at: harness.userConfigURL)
        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }

    func testRollbackRemovalFailureIsVisibleAndKeepsTheBackup() throws {
        let harness = try makeHarness(removeConfig: { _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        _ = try harness.adapter.apply()

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
    }

    func testRollbackRefusesToDeleteAConfigCreatedConcurrently() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        let concurrent = Data(#"{"mcpServers":{"other":{"command":"true"}}}"#.utf8)
        try concurrent.write(to: harness.userConfigURL, options: .atomic)

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    func testRollbackRefusesToDeleteAnEmptyConfigCreatedConcurrently() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        try Data().write(to: harness.userConfigURL, options: .atomic)

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.userConfigURL.path))
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), Data())
    }

    func testRollbackDoesNotDeleteAReplacementRacingWithRemoval() throws {
        let concurrent = Data(#"{"mcpServers":{"racing":{"command":"true"}}}"#.utf8)
        var raceDuringRollback = false
        let harness = try makeHarness(moveConfigExclusively: { source, destination in
            if raceDuringRollback {
                try concurrent.write(to: source, options: .atomic)
            }
            let result = destination.path.withCString { destinationPath in
                source.path.withCString { sourcePath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw CursorMCPError.rollbackFailed }
        })
        _ = try harness.adapter.apply()
        raceDuringRollback = true

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    func testRollbackDoesNotOverwriteAReplacementRacingWithRestore() throws {
        let concurrent = Data(#"{"mcpServers":{"racing":{"command":"true"}}}"#.utf8)
        var moveCount = 0
        let harness = try makeHarness(moveConfigExclusively: { source, destination in
            moveCount += 1
            if moveCount == 2 {
                try concurrent.write(to: destination, options: .atomic)
            }
            let result = destination.path.withCString { destinationPath in
                source.path.withCString { sourcePath in
                    Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw CursorMCPError.rollbackFailed }
        })
        let original = Data(#"{"mcpServers":{"original":{"command":"true"}}}"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o640)
        _ = try harness.adapter.apply()
        moveCount = 0

        XCTAssertThrowsError(try harness.adapter.rollback()) { error in
            XCTAssertEqual(error as? CursorMCPError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), concurrent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.backupURL.path))
    }

    func testConnectionRequiresConfigHelperProtocolAndBrokerHealth() throws {
        let harness = try makeHarness()
        XCTAssertFalse(try harness.adapter.verify().connected)

        _ = try harness.adapter.apply()
        let withoutBroker = try harness.adapter.verify()
        XCTAssertTrue(withoutBroker.configReady)
        XCTAssertTrue(withoutBroker.helperReady)
        XCTAssertTrue(withoutBroker.protocolReady)
        XCTAssertFalse(withoutBroker.brokerHealthy)
        XCTAssertFalse(withoutBroker.connected)

        let missingHelper = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.root.appendingPathComponent("missing-helper"),
            brokerSocketPath: harness.socketPath
        )
        let helperMissing = try missingHelper.verify()
        XCTAssertFalse(helperMissing.helperReady)
        XCTAssertFalse(helperMissing.protocolReady)
        XCTAssertFalse(helperMissing.connected)
    }

    func testConnectionRejectsAnExecutableHelperThatFailsSignatureTrust() throws {
        let harness = try makeHarness()
        _ = try harness.adapter.apply()
        let untrusted = CursorUserMCPAdapter(
            homeDirectory: harness.home,
            backupDirectory: harness.backupDirectory,
            helperURL: harness.helperURL,
            brokerSocketPath: harness.socketPath,
            signing: CodexHelperSigning { _ in false }
        )

        let status = try untrusted.status()

        XCTAssertTrue(status.configReady)
        XCTAssertFalse(status.helperReady)
        XCTAssertFalse(status.protocolReady)
        XCTAssertFalse(status.connected)
    }

    func testRepeatedApplyKeepsThePreAskKeyBackup() throws {
        let harness = try makeHarness()
        let original = Data(#"{ "mcpServers": { "keep": { "command": "true" } } }"#.utf8)
        try harness.writeUserConfig(original, permissions: 0o644)
        _ = try harness.adapter.apply()
        _ = try harness.adapter.apply()
        try harness.adapter.rollback()
        XCTAssertEqual(try Data(contentsOf: harness.userConfigURL), original)
        XCTAssertEqual(try harness.permissions(harness.userConfigURL), 0o644)
    }

    func testProtocolRequiresJSONRPCVersionIdAndAbsenceOfError() throws {
        let harness = try makeHarness(helperURL: try fakeHelper(
            lines: [
                #"{"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey"}}}"#,
                #"{"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}"#,
            ]
        ))
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            let status = try harness.adapter.verify()
            XCTAssertTrue(status.configReady)
            XCTAssertTrue(status.brokerHealthy)
            XCTAssertFalse(status.protocolReady)
            XCTAssertFalse(status.connected)
        }
    }

    func testConnectionRejectsAMismatchedHelperVersion() throws {
        let harness = try makeHarness(helperURL: try fakeHelper(
            lines: [
                #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"9.9.9"}}}"#,
                #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}"#,
            ]
        ))
        _ = try harness.adapter.apply()
        try harness.withBroker { _ in
            let status = try harness.adapter.status()
            XCTAssertTrue(status.helperReady)
            XCTAssertFalse(status.protocolReady)
            XCTAssertFalse(status.connected)
        }
    }

    func testProtocolRejectsBooleanAndFractionalResponseIDs() throws {
        let initialize = #"{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey"}}"#
        let tools = #"{"tools":[{"name":"list_credentials"},{"name":"run"}]}"#
        for lines in [
            [
                #"{"jsonrpc":"2.0","id":true,"result":\#(initialize)}"#,
                #"{"jsonrpc":"2.0","id":2,"result":\#(tools)}"#,
            ],
            [
                #"{"jsonrpc":"2.0","id":1.5,"result":\#(initialize)}"#,
                #"{"jsonrpc":"2.0","id":2.9,"result":\#(tools)}"#,
            ],
        ] {
            let harness = try makeHarness(helperURL: try fakeHelper(lines: lines))
            _ = try harness.adapter.apply()
            try harness.withBroker { _ in
                let status = try harness.adapter.verify()
                XCTAssertTrue(status.configReady)
                XCTAssertTrue(status.brokerHealthy)
                XCTAssertFalse(status.protocolReady)
                XCTAssertFalse(status.connected)
            }
        }
    }

    func testVerifyReturnsWhenHelperIgnoresTermination() throws {
        let helper = try termIgnoringHelper()
        let harness = try makeHarness(helperURL: helper)
        defer {
            let pkill = Process()
            pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkill.arguments = ["-9", "-f", helper.path]
            try? pkill.run()
            pkill.waitUntilExit()
        }
        _ = try harness.adapter.apply()
        let finished = expectation(description: "verify returned")
        var status: CursorMCPConnectionStatus?
        DispatchQueue.global(qos: .userInitiated).async {
            status = try? harness.adapter.verify()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(status?.connected, false)
        XCTAssertEqual(status?.protocolReady, false)
    }

    func testDoesNotReadRealHomeCursorMCPJSON() throws {
        let source = try String(contentsOfFile: #filePath, encoding: .utf8)
        let needle = ["homeDirectory", "ForCurrentUser"].joined()
        XCTAssertFalse(source.contains(needle), "adapter tests must not snapshot Hogan's ~/.cursor/mcp.json")
    }

    private func fakeHelper(lines: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-cursor-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fake-mcp")
        var script = "#!/bin/sh\nwhile IFS= read -r _; do :; done\n"
        for line in lines {
            script += "printf '%s\\n' '" + line.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
        }
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func termIgnoringHelper() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ak-cursor-term-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ignore-term.c")
        let binary = directory.appendingPathComponent("ignore-term")
        try """
        #include <signal.h>
        #include <unistd.h>
        int main(void) {
            signal(SIGTERM, SIG_IGN);
            for (;;) pause();
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compile.arguments = [source.path, "-o", binary.path]
        compile.standardOutput = FileHandle.nullDevice
        compile.standardError = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        XCTAssertEqual(compile.terminationStatus, 0)
        return binary
    }
}

private struct Harness {
    let root: URL
    let home: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let adapter: CursorUserMCPAdapter
    let userConfigURL: URL
    let projectConfigURL: URL
    let cliSpecificURL: URL
    let backupURL: URL

    init(
        replaceConfig: ((URL, URL) throws -> Void)? = nil,
        removeConfig: ((URL) throws -> Void)? = nil,
        moveConfigExclusively: ((URL, URL) throws -> Void)? = nil,
        removeBackupItem: ((URL) throws -> Void)? = nil,
        helperURL: URL? = nil
    ) throws {
        let suffix = UUID().uuidString.prefix(8)
        let root = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-cursor-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
        let cursorDir = home.appendingPathComponent(".cursor", isDirectory: true)
        let projectDir = root.appendingPathComponent("project/.cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let projectConfigURL = projectDir.appendingPathComponent("mcp.json")
        try Data(#"{ "mcpServers": { "project-only": {} } }"#.utf8).write(to: projectConfigURL)
        let helperURL = try helperURL ?? Self.locateHelper()
        let socketPath = root.appendingPathComponent("broker.sock").path
        self.root = root
        self.home = home
        self.backupDirectory = backupDirectory
        self.helperURL = helperURL
        self.socketPath = socketPath
        self.userConfigURL = cursorDir.appendingPathComponent("mcp.json")
        self.projectConfigURL = projectConfigURL
        self.cliSpecificURL = cursorDir.appendingPathComponent("cli-config.json")
        self.backupURL = backupDirectory.appendingPathComponent("cursor-mcp.json")
        self.adapter = CursorUserMCPAdapter(
            homeDirectory: home,
            backupDirectory: backupDirectory,
            helperURL: helperURL,
            brokerSocketPath: socketPath,
            signing: .development,
            replaceConfig: replaceConfig,
            removeConfig: removeConfig,
            moveConfigExclusively: moveConfigExclusively,
            removeBackupItem: removeBackupItem
        )
    }

    func writeUserConfig(_ text: String, permissions: Int) throws {
        try writeUserConfig(Data(text.utf8), permissions: permissions)
    }

    func writeUserConfig(_ data: Data, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: userConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: userConfigURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: userConfigURL.path
        )
    }

    func userJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: userConfigURL)
        let json = try JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any] else {
            throw CursorMCPError.invalidJSON
        }
        return object
    }

    func permissions(_ url: URL) throws -> Int {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return Int(value?.uint16Value ?? 0)
    }

    func withBroker(_ body: (BrokerSocketServer) throws -> Void) throws {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        defer { server.stop() }
        try body(server)
    }

    private static func locateHelper() throws -> URL {
        let url = Bundle(for: CursorUserMCPAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "CursorUserMCPAdapterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "askkey helper not found at \(url.path)",
            ])
        }
        return url
    }
}
