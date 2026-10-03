import Darwin
import Foundation
import XCTest
@testable import AskKeyApp
@testable import AskKeyCore

final class AgentOnboardingBoundaryEvidenceTests: AskKeyAppTestCase {
    private var recorder: OnboardingBoundaryObserver.Recorder!

    override func setUp() {
        super.setUp()
        recorder = OnboardingBoundaryObserver.Recorder()
        OnboardingBoundaryObserver.install(recorder)
    }

    override func tearDown() {
        OnboardingBoundaryObserver.endPageWindow()
        OnboardingBoundaryObserver.install(nil)
        recorder = nil
        super.tearDown()
    }

    func testPositiveControlIncrementsEachBoundaryOnceWired() throws {
        try OnboardingBoundaryObserver.$active.withValue(true) {
            try triggerIsolatedBoundaries()
        }
        XCTAssertGreaterThan(recorder.count(.cli), 0, "CLI seam must increment")
        XCTAssertGreaterThan(recorder.count(.keychain), 0, "keychain intercept must increment")
        XCTAssertGreaterThan(recorder.count(.configWrite), 0, "config write seam must increment")
        XCTAssertGreaterThan(recorder.count(.cursorHelper), 0, "Cursor helper Process start must increment")
    }

    func testPageWindowDetectsBypassOfBoundOperations() throws {
        OnboardingBoundaryObserver.beginPageWindow()
        try triggerIsolatedBoundaries()
        XCTAssertGreaterThan(recorder.count(.cli), 0)
        XCTAssertGreaterThan(recorder.count(.keychain), 0)
        XCTAssertGreaterThan(recorder.count(.configWrite), 0)
        XCTAssertGreaterThan(recorder.count(.cursorHelper), 0, "page window must see CursorUserMCPAdapter.probeMCP")
    }

    func testInactiveObserverDoesNotIncrementWhenBrokerLikeCLIRuns() throws {
        _ = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2,
                maximumOutputBytes: 64
            )
        )
        XCTAssertEqual(recorder.count(.cli), 0)
        XCTAssertEqual(recorder.count(.keychain), 0)
        XCTAssertEqual(recorder.count(.configWrite), 0)
        XCTAssertEqual(recorder.count(.cursorHelper), 0)
    }

    func testAppearExplainTenCyclesDoNotTouchProductionBoundaries() async throws {
        OnboardingBoundaryObserver.beginPageWindow()
        try triggerIsolatedBoundaries()
        XCTAssertGreaterThan(recorder.count(.cli), 0)
        XCTAssertGreaterThan(recorder.count(.cursorHelper), 0)
        recorder.reset()
        XCTAssertTrue(OnboardingBoundaryObserver.isPageWindowActive)

        let home = try makeDirectory("boundary-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let connector = AgentClientConnector(
            home: home,
            installationHome: home,
            supportDirectory: support
        )
        let operations = AgentOnboardingRuntime.liveOperations(
            connector: connector,
            authenticate: { .cancelled }
        )
        let coordinator = await MainActor.run {
            AgentOnboardingCoordinator(operations: operations)
        }
        for _ in 0..<10 {
            await MainActor.run {
                coordinator.appear()
                for client in AgentClient.allCases {
                    coordinator.explain(client)
                }
                coordinator.disappear()
            }
        }
        XCTAssertTrue(OnboardingBoundaryObserver.isPageWindowActive)
        XCTAssertEqual(recorder.count(.cli), 0)
        XCTAssertEqual(recorder.count(.keychain), 0)
        XCTAssertEqual(recorder.count(.configWrite), 0)
        XCTAssertEqual(recorder.count(.cursorHelper), 0)
        let sessions = await MainActor.run { AgentClient.allCases.map { coordinator.session(for: $0) } }
        XCTAssertTrue(sessions.allSatisfy { $0.attempt.phase != .checking })
    }

    func testExplicitCheckThroughLiveOperationsIncrementsObservedBoundary() async throws {
        let home = try makeDirectory("boundary-check")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let sleepCLI = try makeSleepExecutable(directory: bin, name: "codex")
        XCTAssertEqual(sleepCLI.lastPathComponent, "codex")
        let connector = AgentClientConnector(
            home: home,
            installationHome: home,
            supportDirectory: support,
            helperURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let operations = AgentOnboardingRuntime.liveOperations(
            connector: connector,
            authenticate: { .cancelled }
        )
        let coordinator = await MainActor.run {
            AgentOnboardingCoordinator(operations: operations)
        }
        let task = Task { @MainActor in
            await coordinator.startCheck(.codex)
        }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, recorder.count(.cli) == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await MainActor.run { coordinator.cancelCheck(.codex) }
        await task.value
        XCTAssertGreaterThan(recorder.count(.cli), 0)
        await MainActor.run {
            XCTAssertNotEqual(coordinator.session(for: .codex).attempt.failure, .timedOut)
        }
    }

    func testReadonlyCheckLeavesLocalConfigBytesAndModeUnchanged() throws {
        let home = try makeDirectory("readonly-bytes")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["codex", "grok"] {
            let url = bin.appendingPathComponent(name)
            let script = name == "codex"
                ? "#!/bin/sh\necho '0.42.0'\nexit 0\n"
                : "#!/bin/sh\nexit 0\n"
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let connector = AgentClientConnector(
            home: home,
            installationHome: home,
            supportDirectory: support,
            helperURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let fixtures: [(AgentClient, URL, Data)] = [
            (
                .codex,
                CodexUserMCP.userConfigURL(home: home),
                Data("[mcp_servers.other]\ncommand = \"keep\"\n".utf8)
            ),
            (
                .cursor,
                home.appendingPathComponent(".cursor/mcp.json"),
                Data(#"{"mcpServers":{"other":{"command":"keep"}}}"#.utf8)
            ),
            (
                .grok,
                home.appendingPathComponent(".grok/config.toml"),
                Data("[mcp_servers.other]\ncommand = \"keep\"\n".utf8)
            )
        ]
        for (_, url, bytes) in fixtures {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        for (client, url, bytes) in fixtures {
            let beforeMode = try mode(of: url)
            _ = try connector.check(client)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try mode(of: url), beforeMode)
        }
    }

    func testCodexAndGrokApplyStopWhenAskKeyAppearsAfterCheck() throws {
        let home = try makeDirectory("askkey-appear")
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let connector = AgentClientConnector(
            home: home,
            installationHome: home,
            supportDirectory: support,
            helperURL: URL(fileURLWithPath: "/usr/bin/true")
        )
        let cases: [(AgentClient, URL, Data)] = [
            (
                .codex,
                CodexUserMCP.userConfigURL(home: home),
                Data("[mcp_servers.askkey]\ncommand = \"/usr/bin/true\"\nargs = [\"mcp\"]\n".utf8)
            ),
            (
                .grok,
                home.appendingPathComponent(".grok/config.toml"),
                Data("[mcp_servers.askkey]\ncommand = \"/usr/bin/true\"\nargs = [\"mcp\"]\n".utf8)
            )
        ]
        for (client, url, bytes) in cases {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let plan = AgentOnboardingPlan(
                client: client,
                createdAt: Date(timeIntervalSince1970: 1),
                targetIdentity: client.rawValue,
                scopeSummary: "scope",
                configurationPresent: false,
                verifiesOnly: false,
                preconditionSummary: "backup"
            )
            XCTAssertThrowsError(try connector.apply(client, plan: plan)) { error in
                XCTAssertEqual(error as? AgentOnboardingFailure, .planChanged)
            }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertEqual(try mode(of: url), 0o600)
        }
    }

    private func triggerIsolatedBoundaries() throws {
        _ = try RestrictedProcess.run(
            RestrictedProcess.Request(
                executable: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin"],
                timeout: 2,
                maximumOutputBytes: 64
            )
        )
        OnboardingBoundaryObserver.probeRejectedKeychain()
        try OnboardingBoundaryObserver.probeCursorHelperLaunch()
        let directory = try makeDirectory("boundary-write")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("config.toml")
        try ClientConfigFileIO.publishAtomically(
            Data("x = 1\n".utf8),
            to: target,
            mode: 0o600,
            exclusive: true,
            temporaryPrefix: ".askkey-e1-"
        )
    }

    private func makeDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("askkey-e1-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSleepExecutable(directory: URL, name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let script = """
        #!/bin/sh
        exec /bin/sleep 30
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func mode(of url: URL) throws -> mode_t {
        var info = stat()
        XCTAssertEqual(url.path.withCString { lstat($0, &info) }, 0)
        return info.st_mode & 0o777
    }
}
