import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
@testable import AskKeyIntegrations

final class GrokCLIConfigurationTests: GrokCLIAdapterTests {
    func testRedactedDiffCoversCompactAndMultilineInlineEnvironmentTables() {
        let before = """
        [mcp_servers.first]
        env={ AWS_ACCESS_KEY_ID="compact-secret" }
        [mcp_servers.second]
        env = {
          BRACE_VALUE = "}"
          # } does not close the environment table
          ORDINARY_NAME = "multiline-secret"
        }
        """

        let diff = GrokUserTOML.redactedDiff(before: before, after: before + "\n# changed")

        XCTAssertFalse(diff.contains("compact-secret"))
        XCTAssertFalse(diff.contains("multiline-secret"))
        XCTAssertTrue(diff.contains("***"))
    }
    func testPreviewShowsRedactedDesiredDiffWithoutWriting() throws {
        let fixture = try Fixture()
        let original = """
        [ui]
        simple_mode = true

        [mcp_servers.other.env] # retained table comment
        ORDINARY_NAME = "sensitive-ordinary-value"
        AWS_ACCESS_KEY_ID = "sensitive-access-id"
        password = "sensitive-password"

        [mcp_servers.headers]
        headers = { "X-API-Key" = "sensitive-header-key" }

        [mcp_servers.other.headers]
        ORDINARY_HEADER = "sensitive-custom-header"

        mcp_servers.other.env.ORDINARY_NAME = "sensitive-dotted-env"
        """
        try Data(original.utf8).write(to: fixture.configURL)

        let diff = try fixture.adapter().preview()

        XCTAssertTrue(diff.contains("mcp_servers.askkey"))
        XCTAssertTrue(diff.contains("***"))
        XCTAssertFalse(diff.contains(fixture.socketPath))
        XCTAssertFalse(diff.contains("sensitive-access-id"))
        XCTAssertFalse(diff.contains("sensitive-password"))
        XCTAssertFalse(diff.contains("sensitive-ordinary-value"))
        XCTAssertFalse(diff.contains("sensitive-header-key"))
        XCTAssertFalse(diff.contains("sensitive-custom-header"))
        XCTAssertFalse(diff.contains("sensitive-dotted-env"))
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), original)
    }
    func testPreviewNeverDeletesAPreexistingSiblingProbeDirectory() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeExecutable(
            name: "grok-with-diagnostics",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo "[]"
              exit 0
            fi
            exit 1
            """
        )
        let probe = fixture.grokHome.deletingLastPathComponent().appendingPathComponent("probe")
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        let sentinel = probe.appendingPathComponent("user-file.txt")
        try Data("keep".utf8).write(to: sentinel)

        let adapter = fixture.adapter(grokExecutable: grok)
        _ = try adapter.preview()

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertThrowsError(try adapter.grokTOMLDiagnostics("[ui]\n", probe: probe))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))

        let ownedProbe = fixture.directory.appendingPathComponent("owned-probe")
        _ = try adapter.grokTOMLDiagnostics("[ui]\nsimple_mode = true\n", probe: ownedProbe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedProbe.path))
    }
    func testDiagnosticsCleanupFailureIsVisible() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeExecutable(
            name: "grok-diagnostics-cleanup",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            echo "[]"
            exit 0
            """
        )
        let adapter = fixture.adapter(
            grokExecutable: grok,
            removeDiagnosticsProbe: { _ in throw CocoaError(.fileWriteUnknown) }
        )

        XCTAssertThrowsError(
            try adapter.preview()
        ) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .diagnosticsCleanupFailed)
        }
    }
    func testConnectRefusesSymlinkConfigAndLeavesTargetUntouched() throws {
        let fixture = try Fixture()
        let target = fixture.directory.appendingPathComponent("real.toml")
        try Data("# keep\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.configURL, withDestinationURL: target)

        XCTAssertThrowsError(try fixture.adapter().connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .unsafeConfig)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# keep\n")
        XCTAssertTrue(fixture.configURL.isSymlink)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupDataURL.path))
    }
    func testConnectRefusesDirectoryConfig() throws {
        let fixture = try Fixture()
        try FileManager.default.createDirectory(at: fixture.configURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.adapter().connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .unsafeConfig)
        }
    }
    func testConnectRefusesIllegalTOMLWithoutClobbering() throws {
        let fixture = try Fixture()
        let original = Data("not = toml [[\n".utf8)
        try original.write(to: fixture.configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.configURL.path)

        XCTAssertThrowsError(try fixture.adapter(grokExecutable: fixture.missingGrok).connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .invalidConfig)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), original)
        XCTAssertEqual(try fixture.posixMode(at: fixture.configURL), 0o640)
    }
    func testAtomicWriteCreatesTemporaryConfigAs0600BeforeWriting() throws {
        let fixture = try Fixture()
        let observedModes = LockedModes()
        var adapter = fixture.adapter()
        adapter.observeAtomicWriteTemporary = { temporary in
            var st = stat()
            guard lstat(temporary.path, &st) == 0 else { return }
            observedModes.append(Int16(st.st_mode & 0o777))
        }
        let previousMask = umask(0o022)
        defer { _ = umask(previousMask) }

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .verificationFailed("list_unavailable"))
        }
        XCTAssertEqual(observedModes.values, [0o600])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configURL.path))
    }
    func testUnknownGrokMCPWithoutScopeFailsClosed() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeExecutable(
            name: "legacy-grok",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "legacy mcp add"
              exit 0
            fi
            echo "should not be invoked" >&2
            exit 1
            """
        )
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        let original = try Data(contentsOf: fixture.configURL)

        XCTAssertThrowsError(try fixture.adapter(grokExecutable: grok).connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .unsupportedClient)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), original)
    }
    func testMissingOfficialCLIDoesNotClaimConnectedAndRestoresOriginalTOML() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        let original = """
        # keep this comment
        [ui]
        simple_mode = true

        [mcp_servers.other]
        command = "/usr/bin/echo"
        args = ["hello"]
        enabled = true

        # trailing comment
        """
        try Data(original.utf8).write(to: fixture.configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.configURL.path)

        XCTAssertThrowsError(try fixture.adapter(grokExecutable: fixture.missingGrok).connect()) { error in
            guard case GrokCLIAdapterError.verificationFailed("list_unavailable") = error else {
                return XCTFail("expected list_unavailable, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), original)
        XCTAssertEqual(try fixture.posixMode(at: fixture.configURL), 0o640)
        XCTAssertFalse(try String(contentsOf: fixture.configURL, encoding: .utf8).contains("[mcp_servers.askkey]"))
        XCTAssertFalse(try fixture.projectConfigChanged())
    }
    func testOfficialCLIAddsStdioAskKeyAndLeavesProjectAndCompatFilesUntouched() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        try fixture.writeCompatAskKeyServers()
        try Data(
            """
            [ui]
            simple_mode = true

            [mcp_servers.other]
            command = "/usr/bin/echo"
            args = ["hello"]
            enabled = true
            """.utf8
        ).write(to: fixture.configURL)

        let result = try fixture.adapter(grokExecutable: grok).connect()
        XCTAssertTrue(result.connected, result.reason)
        XCTAssertFalse(result.listJSON.contains("https://"))
        XCTAssertTrue(result.doctorJSON.contains("\"healthy\": true") || result.doctorJSON.contains("\"healthy\":true"))
        XCTAssertEqual(result.helperVersion, AskKeyVersion.current)

        let listed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.listJSON.utf8)) as? [[String: Any]])
        let askkey = try XCTUnwrap(listed.first { $0["name"] as? String == "askkey" })
        XCTAssertEqual(askkey["command"] as? String, fixture.helperURL.path)
        XCTAssertEqual(askkey["args"] as? [String], ["mcp"])
        XCTAssertEqual(askkey["scope"] as? String, "user")
        XCTAssertNil(askkey["url"])

        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[mcp_servers.other]"))
        XCTAssertTrue(text.contains("[mcp_servers.askkey]"))
        XCTAssertFalse(text.contains("url ="))
        XCTAssertEqual(try fixture.compatCursorData(), fixture.originalCursorData)
        XCTAssertEqual(try fixture.compatClaudeData(), fixture.originalClaudeData)
        XCTAssertFalse(try fixture.projectConfigChanged())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupDataURL.path))
    }
    func testConnectCreatesItsMissingIsolatedProcessHome() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        try FileManager.default.removeItem(at: fixture.isolatedHome)

        let result = try fixture.adapter(grokExecutable: grok).connect()

        XCTAssertTrue(result.connected, result.reason)
        XCTAssertEqual(try fixture.posixMode(at: fixture.isolatedHome), 0o700)
    }
    func testBlockedIsolatedProcessHomeUsesTheConfigurationErrorBoundary() throws {
        let fixture = try Fixture()
        let blockingFile = fixture.directory.appendingPathComponent("blocked-home")
        try Data("not a directory".utf8).write(to: blockingFile)
        let adapter = GrokCLIAdapter(
            grokHome: fixture.grokHome,
            isolatedHome: blockingFile.appendingPathComponent("child"),
            helperExecutable: fixture.helperURL,
            grokExecutable: fixture.missingGrok,
            backupDirectory: fixture.backupDirectory,
            brokerSocketPath: fixture.socketPath,
            signing: .development
        )

        XCTAssertThrowsError(try adapter.status()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .unsafeConfig)
        }
    }
    func testRemoteConnectorIsNotConnectedAndConnectReplacesItWithStdio() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        try Data(
            """
            [mcp_servers.askkey]
            url = "https://mcp.grok.com/connector"
            enabled = true
            """.utf8
        ).write(to: fixture.configURL)

        let status = try fixture.adapter(grokExecutable: grok).status()
        XCTAssertFalse(status.connected)
        XCTAssertEqual(status.reason, "remote_connector")
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8).contains("https://mcp.grok.com/connector"), true)

        let result = try fixture.adapter(grokExecutable: grok).connect()
        XCTAssertTrue(result.connected, result.reason)
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertFalse(text.contains("https://mcp.grok.com/connector"))
        XCTAssertTrue(text.contains("command = \"\(fixture.helperURL.path)\""))
        XCTAssertFalse(result.listJSON.contains("mcp.grok.com"))
    }
    func testVerificationFailureRestoresOriginalBytesPermissionsAndLeavesNoDuplicate() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        let original = Data(
            """
            # original
            [mcp_servers.other]
            command = "/usr/bin/echo"
            args = ["hello"]
            enabled = true
            """.utf8
        )
        try original.write(to: fixture.configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.configURL.path)

        XCTAssertThrowsError(try fixture.adapter(grokExecutable: grok, brokerSocketPath: fixture.socketPath).connect()) { error in
            guard case GrokCLIAdapterError.verificationFailed = error else {
                return XCTFail("expected verificationFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), original)
        XCTAssertEqual(try fixture.posixMode(at: fixture.configURL), 0o640)
        XCTAssertFalse(try String(contentsOf: fixture.configURL, encoding: .utf8).contains("[mcp_servers.askkey]"))
        XCTAssertEqual(
            try String(contentsOf: fixture.configURL, encoding: .utf8)
                .components(separatedBy: "[mcp_servers.askkey]").count,
            1
        )
    }
    func testConcurrentRewriteBeforeRollbackIsPreserved() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        let concurrent = Data("[ui]\nsimple_mode = false\n".utf8)
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.beforeRollback = {
            try concurrent.write(to: fixture.configURL, options: .atomic)
        }
        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), concurrent)
    }
    func testRewriteAfterReplacementWriteIsNotMisclassifiedAsAskKeyOutput() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        let concurrent = Data("[ui]\nsimple_mode = false\n".utf8)
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.afterReplacementWrite = {
            try concurrent.write(to: fixture.configURL, options: .atomic)
        }
        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), concurrent)
    }
    func testDeleteAfterReplacementWriteIsNotRecreated() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.afterReplacementWrite = {
            try FileManager.default.removeItem(at: fixture.configURL)
        }
        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .rollbackFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configURL.path))
    }
    func testExternalRewriteAfterOfficialPreflightIsNotOverwritten() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        let concurrent = Data("[ui]\nsimple_mode = false\n".utf8)
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.afterOfficialPreflight = {
            try concurrent.write(to: fixture.configURL, options: .atomic)
        }
        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .rollbackFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.configURL), concurrent)
    }
    func testExternalDeleteAfterOfficialPreflightIsNotRecreated() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try Data("[ui]\nsimple_mode = true\n".utf8).write(to: fixture.configURL)
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.afterOfficialPreflight = {
            try FileManager.default.removeItem(at: fixture.configURL)
        }
        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .rollbackFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.configURL.path))
    }
    func testOfficialAddFailureFallsBackToLosslessAndDoesNotLeaveDuplicates() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        try Data(
            """
            # keep
            [mcp_servers.other]
            command = "/usr/bin/echo"
            args = ["hello"]
            enabled = true
            """.utf8
        ).write(to: fixture.configURL)
        let grok = try fixture.writeExecutable(
            name: "failing-grok",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              printf '\\n[mcp_servers.askkey]\\ncommand = "/usr/bin/true"\\nargs = ["mcp"]\\nenabled = true\\n' >> "$GROK_HOME/config.toml"
              echo "add failed" >&2
              exit 1
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}'
              exit 0
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )

        let result = try fixture.adapter(grokExecutable: grok).connect()
        XCTAssertTrue(result.connected, result.reason)
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("# keep"))
        XCTAssertEqual(text.components(separatedBy: "[mcp_servers.askkey]").count, 2)
        XCTAssertTrue(text.contains("command = \"\(fixture.helperURL.path)\""))
        XCTAssertFalse(text.contains("command = \"/usr/bin/true\""))
    }
    func testDoctorNonzeroExitIsNotConnectedEvenWhenHealthyJSON() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        try fixture.writeStdioAskKeyConfig()
        let grok = try fixture.writeExecutable(
            name: "doctor-fail-grok",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}'
              exit 1
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )

        let status = try fixture.adapter(grokExecutable: grok).status()
        XCTAssertFalse(status.connected, status.reason)
        XCTAssertEqual(status.reason, "doctor_unhealthy")
    }
    func testBackupCleanupFailureIsVisibleAndDoesNotRollBackVerifiedConfig() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        let original = Data(
            """
            [mcp_servers.other]
            command = "/usr/bin/echo"
            args = ["hello"]
            enabled = true
            """.utf8
        )
        try original.write(to: fixture.configURL)
        let grok = try fixture.writeExecutable(
            name: "cleanup-fail-grok",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo "--scope user"
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              echo "add failed" >&2
              exit 1
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}'
              exit 0
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )
        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.removeBackupItem = { _ in throw CocoaError(.fileWriteNoPermission) }

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .backupCleanupFailed)
        }
        let text = try String(contentsOf: fixture.configURL, encoding: .utf8)
        XCTAssertTrue(text.contains("[mcp_servers.askkey]"))
        XCTAssertTrue(text.contains("command = \"\(fixture.helperURL.path)\""))
        XCTAssertNotEqual(try Data(contentsOf: fixture.configURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backupStateURL.path))
    }
}
