import Foundation
import XCTest
import AskKeyCore
import AskKeyBroker

final class AuditProcessBoundaryTests: XCTestCase {
    func testHelperVerificationBoundsExitedParentPipeAndStopsItsDescendant() throws {
        let harness = try makeHelperProbe(body: """
        import signal
        import time
        ready_r, ready_w = os.pipe()
        child = os.fork()
        if child == 0:
            os.close(ready_r)
            signal.alarm(4)
            marker = os.path.join(os.path.dirname(__file__), "heartbeat")
            with open(marker, "ab", buffering=0) as stream:
                stream.write(b"x")
                os.write(ready_w, b"r")
                while True:
                    time.sleep(0.01)
                    stream.write(b"x")
        os.close(ready_w)
        os.read(ready_r, 1)
        os._exit(0)
        """)
        defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(harness.adapter.status(), .connected)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        let marker = harness.root.appendingPathComponent("heartbeat")
        let first = try Data(contentsOf: marker)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: marker), first,
            "A probe descendant must stop even when the direct helper has already exited")
    }

    func testHelperTimeoutStopsTheWholeProbeGroup() throws {
        let harness = try makeHelperProbe(body: """
        import signal
        import time
        signal.alarm(4)
        if os.fork() == 0:
            signal.alarm(4)
            with open(os.path.join(os.path.dirname(__file__), "heartbeat"), "ab", buffering=0) as stream:
                while True:
                    stream.write(b"x")
                    time.sleep(0.01)
        time.sleep(4)
        """)
        defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(harness.adapter.status(), .notConnected)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        let marker = harness.root.appendingPathComponent("heartbeat")
        let first = try Data(contentsOf: marker)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(try Data(contentsOf: marker), first)
    }

    func testHelperVerificationBoundsLargeAndContinuousOutput() throws {
        for body in ["os.write(1, b'x' * 2097152)", "while True: os.write(1, b'x' * 8192)"] {
            let harness = try makeHelperProbe(body: body)
            defer { harness.server.stop(); try? FileManager.default.removeItem(at: harness.root) }
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(harness.adapter.status(), .notConnected)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        }
    }

    private func makeHelperProbe(body: String) throws -> (root: URL, adapter: CodexUserMCPAdapter, server: BrokerSocketServer) {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ak-pb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let helper = root.appendingPathComponent("synthetic-helper")
        let script = """
        #!/usr/bin/python3 -I
        import json
        import os
        import sys
        sys.stdin.read()
        print(json.dumps({"jsonrpc": "2.0", "id": 1, "result": {
            "protocolVersion": "2024-11-05", "serverInfo": {"name": "askkey", "version": "0.1.0"}}}), flush=True)
        print(json.dumps({"jsonrpc": "2.0", "id": 2, "result": {
            "tools": [{"name": "list_credentials"}, {"name": "run"}]}}), flush=True)
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
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
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
