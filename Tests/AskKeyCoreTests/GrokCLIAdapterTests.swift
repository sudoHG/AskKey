import AskKeyBroker
import Darwin
import Foundation
import XCTest
@testable import AskKeyCore

final class GrokCLIAdapterTests: AskKeyCoreTestCase {
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
        XCTAssertEqual(result.helperVersion, "0.1.0")

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

    func testStatusTimeoutStopsIgnoredSIGTERMDescendantsAndLeavesUnrelatedProcess() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let heartbeat = fixture.directory.appendingPathComponent("heartbeat")
        let childPidFile = fixture.directory.appendingPathComponent("child.pid")
        let grok = try fixture.writeExecutable(
            name: "hang-grok-heartbeat",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              printf '%s\\n' '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              printf '%s\\n' '[{"command":"\(fixture.helperURL.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              trap '' TERM
              (
                trap '' TERM HUP
                remaining=160
                while [ "$remaining" -gt 0 ]; do
                  printf x >> '\(heartbeat.path)'
                  /bin/sleep 0.05
                  remaining=$((remaining - 1))
                done
              ) &
              printf '%s\\n' "$!" > '\(childPidFile.path)'
              while [ ! -s '\(heartbeat.path)' ]; do /bin/sleep 0.01; done
              wait
            fi
            exit 1
            """
        )
        let control = Process()
        control.executableURL = URL(fileURLWithPath: "/bin/sleep")
        control.arguments = ["20"]
        try control.run()
        var leftovers: [pid_t] = [control.processIdentifier]
        defer {
            if let child = Int32((try? String(contentsOf: childPidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
               child > 1 {
                leftovers.append(child)
            }
            for pid in leftovers where pid > 1 {
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, WNOHANG)
            }
        }

        var adapter = fixture.adapter(grokExecutable: grok)
        adapter.commandTimeout = 0.8
        adapter.terminationGrace = 0.1
        expectStatusTimeout(adapter)

        guard let childPID = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(childPID)
        let goneDeadline = Date().addingTimeInterval(1)
        while Date() < goneDeadline, kill(childPID, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(kill(childPID, 0), 0, "doctor descendant must stop after status() times out")
        XCTAssertEqual(errno, ESRCH)
        let frozen = (try? Data(contentsOf: heartbeat)) ?? Data()
        XCTAssertFalse(frozen.isEmpty, "child must have started heartbeating before cleanup")
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: heartbeat), frozen, "heartbeat must stop after the descendant is reaped")
        XCTAssertEqual(kill(control.processIdentifier, 0), 0, "unrelated process must not be signaled")
        XCTAssertTrue(control.isRunning)
    }

    func testIgnoredSIGTERMAndFilledPipeDoesNotHangConnect() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let childPidFile = fixture.directory.appendingPathComponent("filled-child.pid")
        let grok = try fixture.writeExecutable(
            name: "hang-grok",
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
              trap '' TERM
              (while :; do printf 'untrusted-output-block\\n'; done) &
              echo $! > "\(childPidFile.path)"
              wait
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )
        var leftover: pid_t = 0
        defer { if leftover > 1 { _ = kill(leftover, SIGKILL) } }
        var adapter = fixture.adapter(grokExecutable: grok)
        // Keep the fast preflight reliable under a loaded full-suite runner;
        // the doctor branch still deterministically exceeds this timeout.
        adapter.commandTimeout = 1.0
        adapter.terminationGrace = 0.15
        let started = Date()
        expectStatusTimeout(adapter)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        guard let child = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftover = child
        assertProcessGone(leftover)
        XCTAssertGreaterThan(adapter.lastCapturedOutputBytes, 0)
        XCTAssertLessThanOrEqual(adapter.lastCapturedOutputBytes, BrokerLimits.maximumResponseBytes * 2)
    }

    func testZeroTerminationGraceStillReturnsTimeoutWithoutCrashing() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let childPidFile = fixture.directory.appendingPathComponent("zero-grace-child.pid")
        let doctorStarted = fixture.directory.appendingPathComponent("doctor.started")
        let grok = try fixture.writeExecutable(
            name: "hang-grok-zero-grace",
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
              : > "\(doctorStarted.path)"
              trap '' TERM
              dd if=/dev/zero bs=4096 2>/dev/null &
              echo $! > "\(childPidFile.path)"
              wait
            fi
            echo "unexpected $*" >&2
            exit 1
            """
        )
        var leftover: pid_t = 0
        defer { if leftover > 1 { _ = kill(leftover, SIGKILL) } }
        var adapter = fixture.adapter(grokExecutable: grok)
        // help/list share this per-command budget via try? canUseOfficialGrok();
        // 0.3s under a 115-test suite can miss doctor and return list_unavailable.
        adapter.commandTimeout = 1.0
        adapter.terminationGrace = 0
        let started = Date()
        expectStatusTimeout(adapter, doctorStarted: doctorStarted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: doctorStarted.path), "status() must reach the hanging doctor")
        guard let child = requireChildPID(in: childPidFile, until: Date().addingTimeInterval(1)) else { return }
        leftover = child
        assertProcessGone(leftover)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testSyntheticDoctorSuccessAndNonzeroExitReapTheirDescendants() throws {
        let fixture = try Fixture()
        try fixture.writeStdioAskKeyConfig()
        let successChild = fixture.directory.appendingPathComponent("success-child.pid")
        let failChild = fixture.directory.appendingPathComponent("fail-child.pid")
        let success = try fixture.writeExecutable(
            name: "success-grok",
            contents: syntheticDoctorScript(
                helper: fixture.helperURL.path,
                childPidFile: successChild.path,
                doctorExit: 0
            )
        )
        let failure = try fixture.writeExecutable(
            name: "nonzero-grok",
            contents: syntheticDoctorScript(
                helper: fixture.helperURL.path,
                childPidFile: failChild.path,
                doctorExit: 1
            )
        )
        var leftovers: [pid_t] = []
        defer {
            for pid in leftovers where pid > 1 { _ = kill(pid, SIGKILL) }
        }

        let ok = try fixture.adapter(grokExecutable: success).status()
        XCTAssertFalse(ok.connected)
        XCTAssertEqual(ok.reason, "broker_unhealthy")
        guard let successPID = requireChildPID(in: successChild, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(successPID)
        assertProcessGone(successPID)

        let unhealthy = try fixture.adapter(grokExecutable: failure).status()
        XCTAssertFalse(unhealthy.connected)
        XCTAssertEqual(unhealthy.reason, "doctor_unhealthy")
        guard let failPID = requireChildPID(in: failChild, until: Date().addingTimeInterval(1)) else { return }
        leftovers.append(failPID)
        assertProcessGone(failPID)
    }

    func testOutputCaptureSerializesConcurrentReadsAndWrites() {
        let capture = OutputCapture()
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                for i in 0..<1_000 {
                    capture.bytes = i
                    _ = capture.bytes
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    }

    func testStatusRequiresListDoctorHelperAndBrokerTogether() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        XCTAssertFalse(try fixture.adapter(grokExecutable: grok).status().connected)

        let connected = try fixture.adapter(grokExecutable: grok).connect()
        XCTAssertTrue(connected.connected, connected.reason)

        fixture.stopBroker()
        let withoutBroker = try fixture.adapter(grokExecutable: grok).status()
        XCTAssertFalse(withoutBroker.connected)
        XCTAssertEqual(withoutBroker.reason, "broker_unhealthy")
    }

    func testConnectionRejectsAnExecutableHelperThatFailsSignatureTrust() throws {
        let fixture = try Fixture()
        let grok = try fixture.writeSupportedGrok()
        try fixture.startBroker()
        let adapter = fixture.adapter(
            grokExecutable: grok,
            signing: CodexHelperSigning { _ in false }
        )

        XCTAssertThrowsError(try adapter.connect()) { error in
            XCTAssertEqual(error as? GrokCLIAdapterError, .verificationFailed("helper_signature"))
        }
    }

    func testMissingHelperSpawnKeepsENOENTAndRestoresOriginalTOML() throws {
        let fixture = try Fixture()
        try fixture.startBroker()
        let original = """
        # keep this comment
        [ui]
        simple_mode = true
        """
        try Data(original.utf8).write(to: fixture.configURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.configURL.path)

        let missing = fixture.directory.appendingPathComponent("no-such-helper")
        let grok = try fixture.writeExecutable(
            name: "grok-missing-helper",
            contents: """
            #!/bin/sh
            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              echo '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ]; then
              echo '[{"command":"\(missing.path)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ]; then
              echo '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}]}'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              exit 0
            fi
            exit 1
            """
        )
        var adapter = fixture.adapter(grokExecutable: grok, signing: CodexHelperSigning { _ in true })
        adapter.helperExecutable = missing

        XCTAssertThrowsError(try adapter.connect()) { error in
            guard case GrokCLIAdapterError.verificationFailed(let reason) = error else {
                return XCTFail("expected verificationFailed with POSIX ENOENT, got \(error)")
            }
            let lowered = reason.lowercased()
            XCTAssertTrue(
                lowered.contains("no such file")
                    || lowered.contains("enoent")
                    || reason.contains("无此文件")
                    || reason.contains("\(ENOENT)"),
                "spawn failure must keep the captured POSIX reason, got \(reason)"
            )
        }
        XCTAssertEqual(try String(contentsOf: fixture.configURL, encoding: .utf8), original)
        XCTAssertEqual(try fixture.posixMode(at: fixture.configURL), 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupDataURL.path))
    }
}

private final class Fixture {
    let directory: URL
    let grokHome: URL
    let isolatedHome: URL
    let workingDirectory: URL
    let backupDirectory: URL
    let helperURL: URL
    let socketPath: String
    let missingGrok: URL
    let projectConfigURL: URL
    let cursorURL: URL
    let claudeURL: URL
    var originalCursorData = Data()
    var originalClaudeData = Data()
    var originalProjectData = Data()
    private var broker: BrokerSocketServer?

    var configURL: URL { grokHome.appendingPathComponent("config.toml") }
    var backupDataURL: URL { backupDirectory.appendingPathComponent("grok-cli.config.toml") }
    var backupStateURL: URL { backupDirectory.appendingPathComponent("grok-cli.state") }

    init() throws {
        let suffix = String(UUID().uuidString.prefix(8))
        directory = try physicalTestDirectory(URL(fileURLWithPath: "/tmp", isDirectory: true))
            .appendingPathComponent("ak-g-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)", isDirectory: true)
        grokHome = directory.appendingPathComponent("g", isDirectory: true)
        isolatedHome = directory.appendingPathComponent("h", isDirectory: true)
        workingDirectory = directory.appendingPathComponent("p", isDirectory: true)
        backupDirectory = directory.appendingPathComponent("b", isDirectory: true)
        missingGrok = directory.appendingPathComponent("no-grok")
        projectConfigURL = workingDirectory.appendingPathComponent(".grok/config.toml")
        cursorURL = isolatedHome.appendingPathComponent(".cursor/mcp.json")
        claudeURL = isolatedHome.appendingPathComponent(".claude.json")
        let socketCandidate = URL(fileURLWithPath: "/private/tmp/ak-gs-\(ProcessInfo.processInfo.processIdentifier)-\(suffix)")
        try FileManager.default.createDirectory(at: socketCandidate, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let socketRoot = try physicalTestDirectory(socketCandidate)
        socketPath = socketRoot.appendingPathComponent("daemon.sock").path
        helperURL = try Self.askkeyHelper()
        for url in [grokHome, isolatedHome, workingDirectory, backupDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: projectConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        originalProjectData = Data("[mcp_servers.askkey]\nurl = \"https://project.example/mcp\"\n".utf8)
        try originalProjectData.write(to: projectConfigURL)
    }

    deinit {
        broker?.stop()
        try? FileManager.default.removeItem(at: directory)
        socketPath.withCString { _ = unlink($0) }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: socketPath).deletingLastPathComponent())
    }

    func adapter(
        grokExecutable: URL? = nil,
        brokerSocketPath: String? = nil,
        signing: CodexHelperSigning = .development,
        removeDiagnosticsProbe: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) -> GrokCLIAdapter {
        GrokCLIAdapter(
            grokHome: grokHome,
            isolatedHome: isolatedHome,
            helperExecutable: helperURL,
            grokExecutable: grokExecutable ?? missingGrok,
            backupDirectory: backupDirectory,
            brokerSocketPath: brokerSocketPath ?? socketPath,
            signing: signing,
            helperEnvironment: ["ASKKEY_BROKER_SOCKET": brokerSocketPath ?? socketPath,
                                "ASKKEY_DEBUG_RUN_DIRECTORY": URL(fileURLWithPath: brokerSocketPath ?? socketPath).deletingLastPathComponent().path],
            serverName: "askkey",
            removeDiagnosticsProbe: removeDiagnosticsProbe
        )
    }

    func startBroker() throws {
        let server = BrokerSocketServer(
            socketPath: socketPath,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil })
        )
        try server.start()
        broker = server
    }

    func stopBroker() {
        broker?.stop()
        broker = nil
    }

    func posixMode(at url: URL) throws -> Int16 {
        guard let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return value.int16Value
    }

    func writeStdioAskKeyConfig() throws {
        try Data(
            """
            [mcp_servers.askkey]
            command = "\(helperURL.path)"
            args = ["mcp"]
            enabled = true
            """.utf8
        ).write(to: configURL)
    }

    func writeExecutable(name: String, contents: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func writeSupportedGrok() throws -> URL {
        try writeExecutable(
            name: "supported-grok",
            contents: """
            #!/bin/sh
            config="$GROK_HOME/config.toml"
            expected_helper="\(helperURL.path)"

            if [ "$1" = "mcp" ] && [ "$2" = "add" ] && [ "$3" = "--help" ]; then
              printf '%s\\n' '--scope user'
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
              [ "$3" = "--scope" ] && [ "$4" = "user" ] || exit 64
              found_helper=0
              while [ "$#" -gt 0 ]; do
                if [ "$1" = "--" ]; then
                  shift
                  [ "$1" = "$expected_helper" ] || exit 64
                  shift
                  [ "$1" = "mcp" ] || exit 64
                  found_helper=1
                  break
                fi
                shift
              done
              [ "$found_helper" -eq 1 ] || exit 64
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
              if [ -f "$config" ] && grep -Fq "command = \\\"$expected_helper\\\"" "$config"; then
                printf '[{"command":"%s","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]\\n' "$expected_helper"
              else
                printf '[]\\n'
              fi
              exit 0
            fi
            if [ "$1" = "mcp" ] && [ "$2" = "doctor" ] && [ "$3" = "--json" ]; then
              if [ -f "$config" ] && grep -Fq "command = \\\"$expected_helper\\\"" "$config"; then
                printf '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}\\n'
                exit 0
              fi
              printf '{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":false}],"healthy_count":0,"failing_count":1}\\n'
              exit 1
            fi
            exit 64
            """
        )
    }

    func writeCompatAskKeyServers() throws {
        try FileManager.default.createDirectory(
            at: cursorURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        originalCursorData = Data(
            """
            {"mcpServers":{"askkey":{"url":"https://cursor.example/mcp"}}}
            """.utf8
        )
        originalClaudeData = Data(
            """
            {"mcpServers":{"askkey":{"url":"https://claude.example/mcp"}}}
            """.utf8
        )
        try originalCursorData.write(to: cursorURL)
        try originalClaudeData.write(to: claudeURL)
    }

    func compatCursorData() throws -> Data { try Data(contentsOf: cursorURL) }
    func compatClaudeData() throws -> Data { try Data(contentsOf: claudeURL) }

    func projectConfigChanged() throws -> Bool {
        try Data(contentsOf: projectConfigURL) != originalProjectData
    }

    private static func askkeyHelper() throws -> URL {
        let url = Bundle(for: GrokCLIAdapterTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("askkey")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "GrokCLIAdapterTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "askkey helper is not built at \(url.path)",
            ])
        }
        return url
    }
}

private final class LockedModes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int16] = []

    func append(_ mode: Int16) {
        lock.lock()
        storage.append(mode)
        lock.unlock()
    }

    var values: [Int16] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private func syntheticDoctorScript(
    helper: String,
    childPidFile: String,
    doctorExit: Int
) -> String {
    """
    #!/usr/bin/python3 -I
    import os
    import sys
    import time
    args = sys.argv[1:]
    if args[:3] == ["mcp", "add", "--help"]:
        sys.stdout.write("--scope user\\n")
        sys.exit(0)
    if args[:2] == ["mcp", "list"]:
        sys.stdout.write('[{"command":"\(helper)","args":["mcp"],"enabled":true,"name":"askkey","scope":"user"}]\\n')
        sys.exit(0)
    if args[:2] == ["mcp", "doctor"]:
        child = os.fork()
        if child == 0:
            time.sleep(8)
            os._exit(0)
        with open("\(childPidFile)", "w", encoding="utf-8") as stream:
            stream.write(str(child))
        sys.stdout.write('{"servers":[{"name":"askkey","transport":"stdio","target":"askkey mcp","healthy":true}],"healthy_count":1,"failing_count":0}\\n')
        sys.exit(\(doctorExit))
    sys.exit(1)
    """
}

private func expectStatusTimeout(
    _ adapter: GrokCLIAdapter,
    doctorStarted: URL? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        let status = try adapter.status()
        let doctor = doctorStarted.map { FileManager.default.fileExists(atPath: $0.path) }
        XCTFail(
            "expected timeout, got reason=\(status.reason) connected=\(status.connected) doctorStarted=\(String(describing: doctor))",
            file: file,
            line: line
        )
    } catch {
        guard case GrokCLIAdapterError.verificationFailed("timeout") = error else {
            XCTFail("expected timeout, got \(error)", file: file, line: line)
            return
        }
    }
}

private func requireChildPID(
    in url: URL,
    until deadline: Date,
    file: StaticString = #filePath,
    line: UInt = #line
) -> pid_t? {
    let pid = waitForPID(in: url, until: deadline)
    guard pid > 1 else {
        XCTFail("no doctor descendant pid (got \(pid)); refusing to inspect pid 0", file: file, line: line)
        return nil
    }
    return pid
}

private func assertProcessGone(_ pid: pid_t, timeout: TimeInterval = 1) {
    guard pid > 1 else {
        XCTFail("refusing to inspect pid \(pid) as a descendant")
        return
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline, kill(pid, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) must have stopped")
    XCTAssertEqual(errno, ESRCH)
}

private func waitForPID(in url: URL, until deadline: Date) -> pid_t {
    while Date() < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 1 {
            return pid
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return 0
}

private extension URL {
    var isSymlink: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
