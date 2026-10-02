import Foundation
import XCTest
import AskKeyCore
import AskKeyBroker

final class AuditProcessBoundaryTests: XCTestCase {
    func testHelperVerificationBoundsExitedParentPipeAndStopsItsDescendant() throws {
        let harness = try makeHelperProbe(body: """
        heartbeat &
        wait_for_heartbeat
        exit 0
        """)
        defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(harness.adapter.status(), .connected)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        print("Audit exited-parent helper elapsed=\(elapsed)s")
        let marker = harness.root.appendingPathComponent("heartbeat")
        let first = try waitForHeartbeat(at: marker)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: marker), first,
            "A probe descendant must stop even when the direct helper has already exited")
    }

    func testHelperTimeoutStopsTheWholeProbeGroup() throws {
        let harness = try makeHelperProbe(body: """
        heartbeat &
        wait_for_heartbeat
        /bin/sleep 4
        """)
        defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(harness.adapter.status(), .notConnected)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        print("Audit timeout helper elapsed=\(elapsed)s")
        let marker = harness.root.appendingPathComponent("heartbeat")
        let first = try waitForHeartbeat(at: marker)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: marker), first)
    }

    func testHelperVerificationBoundsLargeAndContinuousOutput() throws {
        let bodies = [
            "block=0; while [ \"$block\" -lt 256 ]; do printf 'x%8191s' ''; block=$((block + 1)); done",
            "while :; do printf 'x%8191s' ''; done"
        ]
        for (index, body) in bodies.enumerated() {
            let harness = try makeHelperProbe(body: body)
            defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(harness.adapter.status(), .notConnected)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
            print("Audit output helper \(index) elapsed=\(elapsed)s")
        }
    }

    private func waitForHeartbeat(at marker: URL) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: marker), !data.isEmpty { return data }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func makeHelperProbe(body: String) throws -> (root: URL, adapter: CodexUserMCPAdapter, server: BrokerSocketServer) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-pb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let helper = root.appendingPathComponent("synthetic-helper")
        let script = """
        #!/bin/sh
        while IFS= read -r request; do :; done
        printf '%s\\n' \\
            '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"0.1.0"}}}' \\
            '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}'
        marker="${0%/*}/heartbeat"
        heartbeat() {
            while :; do
                printf x >> "$marker"
                /bin/sleep 0.01
            done
        }
        wait_for_heartbeat() {
            attempt=0
            while [ ! -s "$marker" ]; do
                attempt=$((attempt + 1))
                [ "$attempt" -lt 100 ] || exit 1
                /bin/sleep 0.01
            done
        }
        # RestrictedProcess gives this synthetic helper a private process group.
        # Fail safely if that isolation regresses before using a group watchdog.
        group=$(/bin/ps -o pgid= -p "$$")
        while [ "${group# }" != "$group" ]; do group="${group# }"; done
        [ "$group" = "$$" ] || exit 1
        # Bound every descendant if the test caller abandons the probe.
        (/bin/sleep 4; kill -TERM 0) &
        \(body)
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let config = root.appendingPathComponent("config.toml")
        try Data("[mcp_servers.askkey]\ncommand = \"\(helper.path)\"\nargs = [\"mcp\"]\n".utf8).write(to: config)
        let socket = root.appendingPathComponent("broker.sock").path
        let server = BrokerSocketServer(socketPath: socket,
            handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil }))
        try server.start()
        let adapter = CodexUserMCPAdapter(configURL: config, helperURL: helper,
            backupDirectory: root.appendingPathComponent("backup"), brokerSocketPath: socket,
            command: .missing, signing: .development)
        return (root, adapter, server)
    }

    func testCodexStatusBoundsContinuousOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = root.appendingPathComponent("codex-output-stub")
        try Data("#!/bin/sh\nwhile :; do printf 'untrusted-output-block\\n'; done\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let started = ProcessInfo.processInfo.systemUptime
        _ = ProcessCodexMCPCommand.make(executable: stub).status()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        print("Audit continuous Codex output elapsed=\(elapsed)s")
    }

    func testCodexStatusDoesNotWaitForDescendantToCloseInheritedStdout() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskKeyAuditProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let stub = root.appendingPathComponent("codex-audit-stub")
        // Use the system shell's built-in printf to avoid Python cold start
        // inside the CLI deadline before the version is written. The stub
        // never launches a real client or reads client configuration. Its
        // descendant holds inherited stdout until it exits after four seconds.
        let script = """
        #!/bin/sh
        if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
            printf 'codex-cli 0.153.4\\n'
            /bin/sleep 4 &
        fi
        exit 0
        """
        try Data(script.utf8).write(to: stub, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stub.path
        )

        let command = ProcessCodexMCPCommand.make(executable: stub)
        let started = ProcessInfo.processInfo.systemUptime
        let status = command.status()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        print("Codex descendant-stdout status elapsed=\(elapsed)s")

        XCTAssertEqual(status, .supported(version: "0.153.4"))
        XCTAssertLessThan(
            elapsed,
            3.0,
            "The two-second CLI deadline must also bound pipe draining after the parent exits; elapsed=\(elapsed)s"
        )
    }
}
