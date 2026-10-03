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

    func testEnableReviewedHookWritesOnlyOneTrustStateAndReadsItBack() throws {
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
        XCTAssertEqual(value.keys.sorted(), [harness.hookKey])
        let state = try XCTUnwrap(value[harness.hookKey] as? [String: Any])
        XCTAssertEqual(state["enabled"] as? Bool, true)
        XCTAssertEqual(state["trusted_hash"] as? String, harness.currentHash)

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
        let session = try interactiveSession(
            script: "IFS= read line; printf 'notification\\n'; while :; do sleep 0.04; printf 'notification\\n'; done",
            timeout: 0.5,
            maximumOutputBytes: 4_096
        )
        defer { session.close() }

        try session.writeLine(Data("request".utf8))
        let started = Date()
        var lines = 0
        XCTAssertThrowsError(try {
            while true {
                _ = try session.readLine()
                lines += 1
            }
        }()) { error in
            XCTAssertEqual(error as? RestrictedProcess.InteractiveFailure, .timedOut)
        }
        XCTAssertGreaterThan(lines, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
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

private extension CodexNativeHookClientTests {
    final class Harness {
        enum HookState: Equatable {
            case missing
            case disabled
            case untrusted
        }

        let root: URL
        let codexDirectory: URL
        let hooksURL: URL
        let configURL: URL
        let executable: URL
        let client: CodexNativeHookClient
        let hookKey: String
        let currentHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let originalConfig = Data("model = \"fixture\"\n".utf8)
        private let hookPresent: Bool
        private let initialTrust: String
        private let requestLog: URL

        init(hookState: HookState) throws {
            hookPresent = hookState != .missing
            initialTrust = hookState == .disabled ? "trusted" : "untrusted"
            root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("askkey-native-hook-\(UUID().uuidString)", isDirectory: true)
            codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
            hooksURL = codexDirectory.appendingPathComponent("hooks.json")
            configURL = codexDirectory.appendingPathComponent("config.toml")
            executable = root.appendingPathComponent("codex-fixture")
            hookKey = "\(hooksURL.path):pre_tool_use:0:0"
            requestLog = root.appendingPathComponent("requests.jsonl")
            client = CodexNativeHookClient(executable: executable, userHome: root)

            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
            try writeHooks(state: hookState)
            try originalConfig.write(to: configURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            try writeExecutable()
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func methods() throws -> [String] {
            try requests().compactMap { $0["method"] as? String }
        }

        func arguments() throws -> [String] {
            let data = try Data(contentsOf: root.appendingPathComponent("argv.json"))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String])
        }

        func requests() throws -> [[String: Any]] {
            guard FileManager.default.fileExists(atPath: requestLog.path) else { return [] }
            return try String(contentsOf: requestLog, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        }

        private func writeHooks(state: HookState) throws {
            let hook: [String: Any] = [
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
            let root: [String: Any] = [
                "hooks": [
                    "PreToolUse": state == .missing ? [] : [hook]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try data.write(to: hooksURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
        }

        private func writeExecutable() throws {
            let homeLiteral = String(reflecting: root.path)
            let configLiteral = String(reflecting: configURL.path)
            let hooksLiteral = String(reflecting: hooksURL.path)
            let logLiteral = String(reflecting: requestLog.path)
            let keyLiteral = String(reflecting: hookKey)
            let hashLiteral = String(reflecting: currentHash)
            let hookPresentLiteral = hookPresent ? "True" : "False"
            let initialTrustLiteral = String(reflecting: initialTrust)
            let script = """
            #!/usr/bin/python3
            import json
            import pathlib
            import sys

            home = \(homeLiteral)
            config = \(configLiteral)
            hooks = \(hooksLiteral)
            log_path = pathlib.Path(\(logLiteral))
            hook_key = \(keyLiteral)
            current_hash = \(hashLiteral)
            hook_present = \(hookPresentLiteral)
            enabled = False
            trusted = \(initialTrustLiteral)

            pathlib.Path(sys.argv[0]).with_name("argv.json").write_text(json.dumps(sys.argv[1:]))

            def hook():
                return {
                    "key": hook_key,
                    "currentHash": current_hash,
                    "enabled": enabled,
                    "eventName": "preToolUse",
                    "isManaged": False,
                    "matcher": "^(Bash|mcp__askkey__list_credentials)$",
                    "source": "user",
                    "sourcePath": hooks,
                    "timeoutSec": 3,
                    "trustStatus": trusted,
                    "handlerType": "mcpTool",
                    "server": "askkey",
                    "tool": "credential_discovery_guard",
                    "displayOrder": 0,
                }

            def config_read():
                return {
                    "config": {},
                    "origins": {
                        "hooks": {
                            "name": {"type": "user", "file": config},
                            "version": "fixture-version-1",
                        }
                    },
                    "layers": [{
                        "name": {"type": "user", "file": config},
                        "version": "fixture-version-1",
                        "config": {},
                    }],
                }

            for line in sys.stdin:
                request = json.loads(line)
                with log_path.open("a") as log:
                    log.write(json.dumps(request) + "\\n")
                if "id" not in request:
                    continue
                method = request.get("method")
                if method == "initialize":
                    result = {"userAgent": "fixture", "codexHome": home + "/.codex"}
                elif method == "hooks/list":
                    result = {"data": [{"cwd": home, "errors": [], "hooks": [hook()] if hook_present else [], "warnings": []}]}
                elif method == "config/read":
                    result = config_read()
                elif method == "config/batchWrite":
                    enabled = True
                    trusted = "trusted"
                    result = {"status": "ok"}
                else:
                    result = {}
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
    }
}
