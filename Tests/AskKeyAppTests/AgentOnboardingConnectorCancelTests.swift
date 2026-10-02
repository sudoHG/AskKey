import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

final class AgentOnboardingConnectorCancelTests: XCTestCase {
    func testCodexCheckCancelGoesThroughConnectorAndKillsProcessGroup() async throws {
        try await runConnectorCancel(client: .codex, placeCursorConfig: false)
    }

    func testCursorCheckCancelGoesThroughConnectorProbeAndKillsHelper() async throws {
        try await runConnectorCancel(client: .cursor, placeCursorConfig: true)
    }

    func testGrokCheckCancelGoesThroughConnectorAndKillsProcessGroup() async throws {
        try await runConnectorCancel(client: .grok, placeCursorConfig: false)
    }

    func testCancelBeforeConnectorCheckDoesNotSpawn() async throws {
        let env = try IsolatedCancelHome()
        defer { env.tearDown() }
        let operations = AgentOnboardingRuntime.liveOperations(
            connector: env.connector,
            authenticate: { .cancelled }
        )
        let cancellation = AgentCheckCancellation()
        cancellation.cancel()
        do {
            _ = try await operations.check(.codex, cancellation)
            XCTFail("expected cancelled")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.pidFile(for: .codex).path))
    }

    func testConnectorTimeoutIsNotMappedToCancelled() async throws {
        let env = try IsolatedCancelHome(sleepSeconds: 2)
        defer { env.tearDown() }
        let operations = AgentOnboardingRuntime.liveOperations(
            connector: env.connector,
            authenticate: { .cancelled }
        )
        let started = Date()
        do {
            _ = try await operations.check(.codex, AgentCheckCancellation())
        } catch {
            XCTAssertNotEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testCoordinatorDisappearCancelsConnectorCheckWithoutGlobalError() async throws {
        let env = try IsolatedCancelHome()
        defer { env.tearDown() }
        let operations = AgentOnboardingRuntime.liveOperations(
            connector: env.connector,
            authenticate: { .cancelled }
        )
        let viewModel = await MainActor.run {
            VaultViewModel(runtimeFileCleanupFailures: { false })
        }
        let coordinator = await MainActor.run {
            let coordinator = AgentOnboardingCoordinator(operations: operations)
            viewModel.onboarding = coordinator
            return coordinator
        }
        let task = Task { @MainActor in
            await coordinator.startCheck(.cursor)
        }
        let pid = try await waitForPID(in: env.pidFile(for: .cursor))
        let child = try await waitForPID(in: env.root.appendingPathComponent("cursor.child.pid"))
        await MainActor.run { coordinator.disappear() }
        await task.value
        let session = await MainActor.run { coordinator.session(for: .cursor) }
        let errorMessage = await MainActor.run { viewModel.errorMessage }
        XCTAssertNotEqual(session.attempt.phase, .checking)
        XCTAssertNotEqual(session.attempt.failure, .timedOut)
        XCTAssertNil(errorMessage)
        assertProcessGone(pid)
        assertProcessGone(child)
        XCTAssertEqual(try Data(contentsOf: env.cursorConfigURL), env.cursorConfigBytes)
        XCTAssertEqual(try mode(of: env.cursorConfigURL), 0o600)
    }

    private func runConnectorCancel(client: AgentClient, placeCursorConfig: Bool) async throws {
        let env = try IsolatedCancelHome(includeCursorConfig: placeCursorConfig)
        defer { env.tearDown() }
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["8"]
        try unrelated.run()
        defer {
            if unrelated.isRunning { unrelated.terminate() }
        }

        let operations = AgentOnboardingRuntime.liveOperations(
            connector: env.connector,
            authenticate: { .cancelled }
        )
        let cancellation = AgentCheckCancellation()
        let started = Date()
        let task = Task<AgentCheckReport, Error> {
            try await operations.check(client, cancellation)
        }
        let pid = try await waitForPID(in: env.pidFile(for: client))
        let child = try await waitForPID(in: env.root.appendingPathComponent("\(client.proofID).child.pid"))
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancelled for \(client)")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled, "\(client) \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        assertProcessGone(pid)
        assertProcessGone(child)
        XCTAssertTrue(unrelated.isRunning)

        let second = AgentCheckCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) {
            second.cancel()
        }
        do {
            _ = try await operations.check(client, second)
            XCTFail("expected second cancelled for \(client)")
        } catch {
            XCTAssertEqual(error as? AgentOnboardingFailure, .cancelled)
        }
        if FileManager.default.fileExists(atPath: env.pidFile(for: client).path) {
            assertProcessGone(try pidFromFile(env.pidFile(for: client)))
        }
        XCTAssertTrue(unrelated.isRunning)
        kill(pid, 0)
        XCTAssertNotEqual(errno, 0)
        XCTAssertEqual(try Data(contentsOf: env.markerConfig(for: client)), env.markerBytes(for: client))
        XCTAssertEqual(try mode(of: env.markerConfig(for: client)), 0o600)
    }

    private func waitForPID(in file: URL) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path),
               let pid = try? pidFromFile(file), pid > 1 {
                return pid
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "connector-cancel", code: 1)
    }

    private func pidFromFile(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int32(text), value > 1 else {
            throw NSError(domain: "connector-cancel", code: 2)
        }
        return value
    }

    private func assertProcessGone(_ pid: pid_t) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("process \(pid) still running")
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(url.path.withCString { lstat($0, &info) }, 0)
        return info.st_mode & 0o777
    }
}

private struct IsolatedCancelHome {
    let root: URL
    let connector: AgentClientConnector
    let cursorConfigBytes: Data
    let cursorConfigURL: URL
    private let includeCursorConfig: Bool

    init(includeCursorConfig: Bool = true, sleepSeconds: Int = 30) throws {
        self.includeCursorConfig = includeCursorConfig
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e2-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cursorConfigURL = root.appendingPathComponent(".cursor/mcp.json")
        let helper = try IsolatedCancelHome.writeSleepCLI(
            named: "askkey-helper",
            seconds: sleepSeconds,
            root: root
        )
        for name in ["codex", "grok"] {
            _ = try IsolatedCancelHome.writeSleepCLI(named: name, seconds: sleepSeconds, root: root)
        }
        cursorConfigBytes = try JSONSerialization.data(
            withJSONObject: [
                "mcpServers": [
                    "askkey": [
                        "command": helper.path,
                        "args": ["mcp"]
                    ]
                ]
            ]
        )
        if includeCursorConfig {
            try FileManager.default.createDirectory(
                at: cursorConfigURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try cursorConfigBytes.write(to: cursorConfigURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: cursorConfigURL.path
            )
        }
        let grok = root.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(
            at: grok.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\n".utf8).write(to: grok)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: grok.path)
        let codex = CodexUserMCP.userConfigURL(home: root)
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("\n".utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codex.path)
        connector = AgentClientConnector(
            home: root,
            installationHome: root,
            supportDirectory: support,
            helperURL: helper
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func pidFile(for client: AgentClient) -> URL {
        root.appendingPathComponent("\(client.proofID).pid")
    }

    func childPID(for client: AgentClient) -> pid_t? {
        let file = root.appendingPathComponent("\(client.proofID).child.pid")
        guard let text = try? String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int32(text), value > 1 else { return nil }
        return value
    }

    func markerConfig(for client: AgentClient) -> URL {
        switch client {
        case .codex: return CodexUserMCP.userConfigURL(home: root)
        case .cursor: return cursorConfigURL
        case .grok: return root.appendingPathComponent(".grok/config.toml")
        }
    }

    func markerBytes(for client: AgentClient) -> Data {
        switch client {
        case .cursor: return cursorConfigBytes
        default: return Data("\n".utf8)
        }
    }

    private static func writeSleepCLI(named name: String, seconds: Int, root: URL) throws -> URL {
        let destination: URL
        if name == "askkey-helper" {
            destination = root.appendingPathComponent("askkey-helper")
        } else {
            destination = root.appendingPathComponent(".local/bin/\(name)")
        }
        let proof = name == "askkey-helper" ? "cursor" : name
        let pid = root.appendingPathComponent("\(proof).pid")
        let child = root.appendingPathComponent("\(proof).child.pid")
        let script = """
        #!/bin/sh
        if [ "$1" = "hook" ] && [ "$2" = "capabilities" ]; then
            printf '%s\\n' '{"protocolVersion":1,"clients":["cursor","grok"]}'
            exit 0
        fi
        echo $$ > '\(pid.path)'
        /bin/sleep \(seconds) &
        echo $! > '\(child.path)'
        wait
        """
        try script.write(to: destination, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        return destination
    }
}
