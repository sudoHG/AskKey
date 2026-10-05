import Darwin
import Foundation
import XCTest
@testable import AskKeyIntegrations
@testable import AskKeySystem

final class CodexNativeHookClientTests: XCTestCase {
    func testStatusReadsTheUserHookThroughInteractiveAppServer() throws {
        let harness = try Harness(hookState: .disabled)

        XCTAssertEqual(try harness.client.status(), .disabled)
        XCTAssertEqual(try harness.methods(), ["initialize", "initialized", "hooks/list"])
        XCTAssertEqual(try harness.arguments(), ["app-server", "--disable", "plugins", "--disable", "apps"])
    }

    func testStatusMapsUntrustedHookSeparatelyFromDisabled() throws {
        let harness = try Harness(hookState: .untrusted)

        XCTAssertEqual(try harness.client.status(), .untrusted)
    }

    func testStatusReportsMissingWhenTheReviewedHookIsNotInstalled() throws {
        let harness = try Harness(hookState: .missing)

        XCTAssertEqual(try harness.client.status(), .missing)
    }

    func testOnlyLegacyOrOneCommandEventRequiresReconnectWithoutTrustWrite() throws {
        for event in ["PreToolUse", "PostToolUse"] {
            let harness = try Harness(hookState: .disabled, onlyEvent: event)
            XCTAssertEqual(try harness.client.status(), .missing)
            XCTAssertThrowsError(try harness.client.enableReviewedHook())
            XCTAssertFalse(try harness.methods().contains("config/batchWrite"))
        }
        let legacy = try Harness(hookState: .disabled, legacy: true)
        XCTAssertEqual(try legacy.client.status(), .missing)
        XCTAssertFalse(try legacy.methods().contains("config/batchWrite"))
    }

    func testTrustUsesActualKeysWithGroupsBeforeAndAfterOurHandlers() throws {
        let harness = try Harness(hookState: .disabled, surroundingGroups: true)
        XCTAssertEqual(try harness.client.enableReviewedHook(), .enabled)
        let write = try XCTUnwrap(try harness.requests().first { $0["method"] as? String == "config/batchWrite" })
        let params = try XCTUnwrap(write["params"] as? [String: Any])
        let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
        let value = try XCTUnwrap(edits.first?["value"] as? [String: Any])
        XCTAssertEqual(Set(value.keys), [harness.hookKey, harness.postHookKey])
        XCTAssertTrue(harness.hookKey.hasSuffix(":pre_tool_use:1:0"))
        XCTAssertTrue(harness.postHookKey.hasSuffix(":post_tool_use:1:0"))
        XCTAssertNil(value["unrelated-disabled"])
        XCTAssertNil(value["legacy-mcp-key"])
    }

    func testInPlaceLegacyKeyUsesNewCurrentHashAndModifiedStatusNeedsTrust() throws {
        let harness = try Harness(hookState: .modified)
        XCTAssertEqual(try harness.client.status(), .untrusted)
        XCTAssertEqual(try harness.client.enableReviewedHook(), .enabled)
        let write = try XCTUnwrap(try harness.requests().first { $0["method"] as? String == "config/batchWrite" })
        let params = try XCTUnwrap(write["params"] as? [String: Any])
        let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
        let value = try XCTUnwrap(edits.first?["value"] as? [String: [String: Any]])
        XCTAssertEqual(value[harness.hookKey]?["trusted_hash"] as? String, harness.currentHash)
        XCTAssertNotEqual(value[harness.hookKey]?["trusted_hash"] as? String,
                          "sha256:de649513d3d2d2d50c5a9747079e3fa5879d89ea2e9fb15238e7923b0efa6c93")
        XCTAssertEqual(Set(value.keys), [harness.hookKey, harness.postHookKey])
        XCTAssertNil(value["legacy-mcp-key"], "Stale entries outside current keys remain untouched")
    }

    func testBothHandlersMustBeEnabledAndTrustedForReadiness() throws {
        let disabledPost = try Harness(hookState: .enabled,
            metadataOverrides: ["postToolUse": ["enabled": false]])
        XCTAssertEqual(try disabledPost.client.status(), .disabled)
        let untrustedPost = try Harness(hookState: .enabled,
            metadataOverrides: ["postToolUse": ["trustStatus": "untrusted"]])
        XCTAssertEqual(try untrustedPost.client.status(), .untrusted)
        let enabled = try Harness(hookState: .enabled)
        XCTAssertEqual(try enabled.client.enableReviewedHook(), .enabled)
        XCTAssertFalse(try enabled.methods().contains("config/batchWrite"))
    }

    func testMismatchedCommandMetadataCannotReceiveTrust() throws {
        for override in [["handlerType": "mcpTool"], ["timeoutSec": 4], ["async": true],
                         ["matcher": "custom"], ["currentHash": "invalid"], ["source": "project"],
                         ["key": "unrelated-disabled"]] as [[String: Any]] {
            let harness = try Harness(hookState: .disabled, metadataOverrides: ["postToolUse": override])
            XCTAssertThrowsError(try harness.client.enableReviewedHook())
            XCTAssertFalse(try harness.methods().contains("config/batchWrite"))
            XCTAssertEqual(try Data(contentsOf: harness.configURL), harness.originalConfig)
        }
    }

    func testConcurrentHookEditStopsTrustAndPreservesTheExternalEdit() throws {
        let harness = try Harness(hookState: .disabled, concurrentHookEdit: true)
        XCTAssertThrowsError(try harness.client.enableReviewedHook())
        XCTAssertFalse(try harness.methods().contains("config/batchWrite"))
        XCTAssertEqual(try Data(contentsOf: harness.configURL), harness.originalConfig)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: harness.hooksURL)) as? [String: Any])
        XCTAssertEqual(root["keep"] as? String, "concurrent")
    }

    func testPublicClientRejectsAUserHomeDifferentFromTheCurrentHome() throws {
        let harness = try Harness(hookState: .disabled)
        let otherHome = harness.root.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: otherHome, withIntermediateDirectories: true)
        let client = CodexNativeHookClient(
            executable: harness.executable,
            userHome: otherHome
        )

        XCTAssertThrowsError(try client.status()) { error in
            XCTAssertEqual(
                error as? CodexNativeHookClientError,
                .userHomeMismatch
            )
        }
    }

    func testEnableReviewedHookWritesOnlyTwoCurrentTrustStatesAndReadsThemBack() throws {
        let harness = try Harness(hookState: .disabled)

        XCTAssertEqual(try harness.client.enableReviewedHook(), .enabled)
        XCTAssertEqual(
            try harness.methods(),
            ["initialize", "initialized", "config/read", "hooks/list", "config/batchWrite", "config/read", "hooks/list"]
        )

        let batchWrite = try XCTUnwrap(try harness.requests().first { $0["method"] as? String == "config/batchWrite" })
        XCTAssertEqual(batchWrite["method"] as? String, "config/batchWrite")
        let params = try XCTUnwrap(batchWrite["params"] as? [String: Any])
        XCTAssertEqual(params["filePath"] as? String, harness.configURL.path)
        XCTAssertEqual(params["expectedVersion"] as? String, "fixture-version-1")
        XCTAssertEqual(params["reloadUserConfig"] as? Bool, true)

        let edits = try XCTUnwrap(params["edits"] as? [[String: Any]])
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0]["keyPath"] as? String, "hooks.state")
        XCTAssertEqual(edits[0]["mergeStrategy"] as? String, "upsert")
        let value = try XCTUnwrap(edits[0]["value"] as? [String: Any])
        XCTAssertEqual(value.keys.sorted(), [harness.hookKey, harness.postHookKey].sorted())
        let state = try XCTUnwrap(value[harness.hookKey] as? [String: Any])
        XCTAssertEqual(state["enabled"] as? Bool, true)
        XCTAssertEqual(state["trusted_hash"] as? String, harness.currentHash)
        let postState = try XCTUnwrap(value[harness.postHookKey] as? [String: Any])
        XCTAssertEqual(postState["enabled"] as? Bool, true)
        XCTAssertEqual(postState["trusted_hash"] as? String, harness.postHash)

        let backupDirectory = harness.root
            .appendingPathComponent("Library/Application Support/AskKey/client-backups/codex-trust", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), harness.originalConfig)
    }

    // Real app-server compatibility is an explicit system probe:
    // scripts/probe-pretool-hook.py --preflight-only --output <new-directory>
    func testStatusLeavesFixtureConfigurationUnchanged() throws {
        let harness = try Harness(hookState: .disabled)
        let originalHooks = try Data(contentsOf: harness.hooksURL)
        let originalConfig = try Data(contentsOf: harness.configURL)
        let originalFiles = try FileManager.default.contentsOfDirectory(atPath: harness.codexDirectory.path).sorted()

        XCTAssertEqual(try harness.client.status(), .disabled)

        XCTAssertEqual(try harness.methods(), ["initialize", "initialized", "hooks/list"])
        XCTAssertEqual(try Data(contentsOf: harness.hooksURL), originalHooks)
        XCTAssertEqual(try Data(contentsOf: harness.configURL), originalConfig)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.codexDirectory.path).sorted(),
                       originalFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.root.appendingPathComponent("Library").path))
    }

    func testEnableReviewedHookRejectsBackupAncestorSymlinkWithoutWritingTrustOrTarget() throws {
        let harness = try Harness(hookState: .disabled)
        let originalHooks = try Data(contentsOf: harness.hooksURL)
        let target = harness.root.appendingPathComponent("trust-backup-target", isDirectory: true)
        let existingChild = target.appendingPathComponent("existing-child", isDirectory: true)
        try FileManager.default.createDirectory(at: existingChild, withIntermediateDirectories: true)
        let sentinel = existingChild.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("keep unrelated trust backup file\n".utf8)
        try sentinelData.write(to: sentinel)
        let alias = harness.root.appendingPathComponent("trust-backup-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertThrowsError(try harness.client.enableReviewedHook(
            backupDirectory: alias.appendingPathComponent("existing-child", isDirectory: true)
        )) { error in
            XCTAssertEqual(error as? CodexNativeHookClientError, .unsafeConfiguration)
        }

        XCTAssertFalse(try harness.methods().contains("config/batchWrite"))
        XCTAssertEqual(try Data(contentsOf: harness.configURL), harness.originalConfig)
        XCTAssertEqual(try Data(contentsOf: harness.hooksURL), originalHooks)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: existingChild.path), ["sentinel.txt"])
    }

    func testEnableReviewedHookAcceptsExistingNestedBackupDirectory() throws {
        let harness = try Harness(hookState: .disabled)
        let backupDirectory = harness.root.appendingPathComponent("ordinary/support/backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        XCTAssertEqual(try harness.client.enableReviewedHook(backupDirectory: backupDirectory), .enabled)

        XCTAssertEqual(try harness.methods().filter { $0 == "config/batchWrite" }.count, 1)
        let backups = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), harness.originalConfig)
    }

    func testInteractiveSessionHonorsCancellationWhileServerIsQuiet() throws {
        let cancelled = LockedFlag()
        let session = try interactiveSession(
            script: "sleep 8",
            timeout: 4,
            isCancelled: { cancelled.value }
        )
        defer { session.close() }

        try session.writeLine(Data("request".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            cancelled.value = true
        }
        let started = Date()
        XCTAssertThrowsError(try session.readLine()) { error in
            XCTAssertEqual(error as? RestrictedProcess.InteractiveFailure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testInteractiveSessionUsesOneDeadlineAcrossNotificationFlood() throws {
        let directory = try makeInteractiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let release = directory.appendingPathComponent("release-flood")
        let session = try interactiveSession(
            script: """
            IFS= read line
            printf 'notification\\n'
            while [ ! -f '\(release.path)' ]; do /bin/sleep 0.01; done
            while :; do printf 'notification\\n'; done
            """,
            timeout: 1,
            maximumOutputBytes: 512
        )
        defer { session.close() }

        try session.writeLine(Data("request".utf8))
        var lines = 0
        XCTAssertThrowsError(try {
            _ = try session.readLine()
            lines += 1
            // Release the flood only after a bounded notification was read.
            // A second writeLine would reset the deadline under test.
            try Data().write(to: release)
            while true {
                _ = try session.readLine()
                lines += 1
            }
        }()) { error in
            XCTAssertEqual(error as? RestrictedProcess.InteractiveFailure, .outputTooLarge)
        }
        XCTAssertGreaterThan(lines, 0)
    }

    func testInteractiveSessionDoesNotResetDeadlineForSlowNotifications() throws {
        let notificationCount = 32
        let session = try interactiveSession(
            script: """
            IFS= read line
            count=0
            while [ "$count" -lt \(notificationCount) ]; do
                printf 'notification\\n'
                count=$((count + 1))
                sleep 0.04
            done
            """,
            timeout: 0.5,
            maximumOutputBytes: 4_096
        )
        defer { session.close() }

        try session.writeLine(Data("request".utf8))
        // The full stream takes at least 31 * 0.04 seconds, beyond the request deadline.
        // Resetting the deadline per notification would let every read succeed.
        // Runner delays may reduce the number read or delay cleanup; neither is a failure.
        XCTAssertThrowsError(try {
            for _ in 0..<notificationCount {
                let notification = try session.readLine()
                XCTAssertEqual(notification, Data("notification".utf8))
            }
        }()) { error in
            XCTAssertEqual(error as? RestrictedProcess.InteractiveFailure, .timedOut)
        }
    }

    func testInteractiveSessionReportsExitAndReapsTheProcessGroup() throws {
        let directory = try makeInteractiveDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("child.pid")
        let quotedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let session = try interactiveSession(
            script: "IFS= read line; (trap '' TERM; sleep 8) & child=$!; echo $child > '\(quotedPIDFile)'; wait",
            directory: directory,
            timeout: 2
        )

        try session.writeLine(Data("request".utf8))
        let child = try waitForPID(in: pidFile)
        session.close()
        assertProcessGone(child)
    }

    func testInteractiveSessionKeepsTheJSONLLineBoundary() throws {
        let session = try interactiveSession(
            script: "IFS= read line; printf 'first\\nsecond\\n'",
            timeout: 1
        )
        defer { session.close() }

        try session.writeLine(Data("request".utf8))
        XCTAssertEqual(String(decoding: try session.readLine(), as: UTF8.self), "first")
        XCTAssertEqual(String(decoding: try session.readLine(), as: UTF8.self), "second")
    }
}

private extension CodexNativeHookClientTests {
    func interactiveSession(
        script: String,
        directory: URL? = nil,
        timeout: TimeInterval,
        maximumInputBytes: Int = 4_096,
        maximumOutputBytes: Int = 1_048_576,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> RestrictedProcess.InteractiveSession {
        let readinessDirectory = try makeInteractiveDirectory()
        defer { try? FileManager.default.removeItem(at: readinessDirectory) }
        let ready = readinessDirectory.appendingPathComponent("ready")
        let session = try RestrictedProcess.startInteractive(
            RestrictedProcess.InteractiveRequest(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf ready > '\(ready.path)'\n\(script)"],
                environment: ["PATH": "/bin:/usr/bin"],
                currentDirectory: directory,
                timeout: timeout,
                maximumInputBytes: maximumInputBytes,
                maximumOutputBytes: maximumOutputBytes,
                terminationGrace: 0,
                isCancelled: isCancelled
            )
        )
        do {
            // Process startup is setup; writeLine starts the request deadline.
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while ProcessInfo.processInfo.systemUptime < deadline {
                if (try? Data(contentsOf: ready)) == Data("ready".utf8) { return session }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTFail("The interactive fixture did not report ready")
            throw CocoaError(.fileReadNoSuchFile)
        } catch {
            session.close()
            throw error
        }
    }

    final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool {
            get { lock.withLock { storage } }
            set { lock.withLock { storage = newValue } }
        }
    }

    func makeInteractiveDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("askkey-native-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func waitForPID(in file: URL) throws -> pid_t {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if let value = try? String(contentsOf: file, encoding: .utf8),
               let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 1 {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CocoaError(.fileNoSuchFile)
    }

    func assertProcessGone(_ pid: pid_t, timeout: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "process \(pid) should be gone")
        XCTAssertEqual(errno, ESRCH)
    }
}
