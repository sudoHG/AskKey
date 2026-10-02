import Foundation
import XCTest
import AskKeyBroker
import AskKeyCore
@testable import AskKeyApp

final class CodexOnboardingSetupTests: XCTestCase {
    func testWorkingMCPWithoutNativeDiscoveryDoesNotCompleteOnboarding() throws {
        let fixture = try CodexSetupFixture()
        defer { fixture.close() }
        _ = try fixture.mcp.apply()
        XCTAssertEqual(fixture.mcp.status(), .connected)
        let original = try Data(contentsOf: fixture.mcp.configURL)

        let report = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )

        XCTAssertEqual(report.outcome, .configuredUnverified)
        XCTAssertEqual(report.discovery, .unavailable)
        XCTAssertNotNil(report.failure)
        XCTAssertNil(report.plan)
        XCTAssertEqual(try Data(contentsOf: fixture.mcp.configURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooksURL.path))
    }

    func testChangingHookAfterReviewStopsBeforeMCPConfiguration() throws {
        let fixture = try CodexSetupFixture()
        defer { fixture.close() }
        var plan = fixture.plan
        plan.codexHookPlan = try fixture.hook.preview()
        let concurrent = Data(#"{"hooks":{"PostToolUse":[]},"keep":"new settings"}"#.utf8)
        try concurrent.write(to: fixture.hooksURL)

        XCTAssertThrowsError(try CodexOnboardingSetup.apply(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: plan
        )) { error in
            XCTAssertEqual(error as? AgentOnboardingFailure, .planChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mcp.configURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.hooksURL), concurrent)
    }

    func testVerifiedMCPMissingHookIsInstalledTrustedAndRetained() throws {
        let fixture = try CodexSetupFixture(
            nativeMode: .missing,
            includeOtherHook: true
        )
        defer { fixture.close() }
        _ = try fixture.mcp.apply()
        XCTAssertEqual(fixture.mcp.status(), .connected)
        let originalMCP = try Data(contentsOf: fixture.mcp.configURL)

        let checked = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )

        XCTAssertEqual(checked.outcome, .configuredUnverified)
        XCTAssertEqual(checked.discovery, .missing)
        let frozen = try XCTUnwrap(checked.plan)
        XCTAssertTrue(try XCTUnwrap(frozen.codexHookPlan).changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hooksURL.path))

        let applied = try CodexOnboardingSetup.apply(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: frozen
        )

        XCTAssertEqual(applied.outcome, .verifiedConnected)
        XCTAssertEqual(applied.changeStatus, .verifiedAndKept)
        XCTAssertNil(applied.failure)
        XCTAssertEqual(applied.discovery, .enabled)
        XCTAssertEqual(try fixture.native.status(), .enabled)
        XCTAssertEqual(fixture.mcp.status(), .connected)
        XCTAssertEqual(try Data(contentsOf: fixture.mcp.configURL), originalMCP)
        XCTAssertTrue(try fixture.hook.hasExpectedHook())

        let document = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(document["hooks"] as? [String: Any])
        let preToolUse = try XCTUnwrap(hooks["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolUse.count, 2)
        XCTAssertEqual(preToolUse[0]["matcher"] as? String, "existing")
        XCTAssertEqual(preToolUse[1]["matcher"] as? String, "^(Bash|mcp__askkey__list_credentials)$")

        let checkedAgain = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )
        XCTAssertEqual(checkedAgain.outcome, .verifiedConnected)
        XCTAssertEqual(checkedAgain.discovery, .enabled)
        XCTAssertNil(checkedAgain.plan)
        XCTAssertNil(checkedAgain.failure)
    }

    func testFirstSetupCreatesMCPAndHookAndNextCheckIsVerified() throws {
        let fixture = try CodexSetupFixture(nativeMode: .missing)
        defer { fixture.close() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mcp.configURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooksURL.path))

        let checked = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )
        XCTAssertEqual(checked.outcome, .notConfigured)
        let frozen = try XCTUnwrap(checked.plan)
        XCTAssertFalse(frozen.configurationPresent)
        let applied = try CodexOnboardingSetup.apply(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: frozen
        )
        XCTAssertNil(applied.failure)
        XCTAssertEqual(applied.outcome, .verifiedConnected)
        XCTAssertEqual(applied.discovery, .enabled)
        XCTAssertEqual(fixture.mcp.status(), .connected)
        XCTAssertTrue(try fixture.hook.hasExpectedHook())

        let checkedAgain = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )
        XCTAssertEqual(checkedAgain.outcome, .verifiedConnected)
        XCTAssertNil(checkedAgain.plan)
    }

    func testVerifiedMCPWithoutHooksFileCreatesItAndNextCheckIsVerified() throws {
        let fixture = try CodexSetupFixture(nativeMode: .missing)
        defer { fixture.close() }
        _ = try fixture.mcp.apply()
        let originalMCP = try Data(contentsOf: fixture.mcp.configURL)

        let checked = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )
        let frozen = try XCTUnwrap(checked.plan)
        XCTAssertEqual(checked.discovery, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooksURL.path))

        let applied = try CodexOnboardingSetup.apply(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: frozen
        )

        XCTAssertEqual(applied.outcome, .verifiedConnected)
        XCTAssertEqual(applied.discovery, .enabled)
        XCTAssertEqual(try Data(contentsOf: fixture.mcp.configURL), originalMCP)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.hooksURL.path))
        XCTAssertTrue(try fixture.hook.hasExpectedHook())
    }

    func testNativeTrustFailureLeavesVerifiedMCPAndReportsIncompleteSetup() throws {
        let fixture = try CodexSetupFixture(
            nativeMode: .trustFailure,
            includeOtherHook: true
        )
        defer { fixture.close() }
        _ = try fixture.mcp.apply()
        XCTAssertEqual(fixture.mcp.status(), .connected)
        let originalMCP = try Data(contentsOf: fixture.mcp.configURL)

        let checked = try CodexOnboardingSetup.check(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: fixture.plan
        )
        let frozen = try XCTUnwrap(checked.plan)

        let applied = try CodexOnboardingSetup.apply(
            mcp: fixture.mcp, hook: fixture.hook, native: fixture.native, plan: frozen
        )

        XCTAssertEqual(applied.outcome, .configuredUnverified)
        XCTAssertEqual(applied.changeStatus, .verifiedAndKept)
        XCTAssertEqual(applied.failure, .discoverySetupFailed)
        XCTAssertEqual(applied.discovery, .unavailable)
        XCTAssertEqual(fixture.mcp.status(), .connected)
        XCTAssertEqual(try Data(contentsOf: fixture.mcp.configURL), originalMCP)
        XCTAssertTrue(try fixture.hook.hasExpectedHook())
        XCTAssertEqual(try fixture.native.status(), .untrusted)
    }
}

private final class CodexSetupFixture {
    enum NativeMode: Equatable {
        case unavailable
        case missing
        case trustFailure
    }

    let root: URL
    let hooksURL: URL
    let mcp: CodexUserMCPAdapter
    let hook: CodexDiscoveryHookConfiguration
    let native: CodexNativeHookClient
    let broker: BrokerSocketServer
    let plan = AgentOnboardingPlan(
        client: .codex, createdAt: Date(), targetIdentity: "Codex", scopeSummary: "",
        configurationPresent: false, verifiesOnly: false,
        preconditionSummary: ""
    )

    init(
        nativeMode: NativeMode = .unavailable,
        includeOtherHook: Bool = false
    ) throws {
        let fixtureRoot = URL(fileURLWithPath: "/tmp/aks-\(UUID().uuidString.prefix(8))", isDirectory: true)
        root = fixtureRoot
        let home = fixtureRoot.appendingPathComponent("home")
        let config = home.appendingPathComponent(".codex/config.toml")
        hooksURL = home.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = Bundle(for: CodexOnboardingSetupTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("askkey")
        let socket = root.appendingPathComponent("b.sock").path
        broker = BrokerSocketServer(socketPath: socket, handler: .init(catalog: { _ in [] }, requestStatus: { _, _ in nil }))
        try broker.start()
        mcp = CodexUserMCPAdapter(configURL: config, helperURL: helper,
                                 backupDirectory: fixtureRoot.appendingPathComponent("mcp-backup"),
                                 brokerSocketPath: socket, signing: .development)
        hook = CodexDiscoveryHookConfiguration(
            hooksURL: hooksURL,
            backupDirectory: fixtureRoot.appendingPathComponent("hook-backup")
        )
        if includeOtherHook {
            try Self.writeOtherHookDocument(to: hooksURL)
        }
        switch nativeMode {
        case .unavailable:
            native = CodexNativeHookClient(executable: URL(fileURLWithPath: "/usr/bin/false"), userHome: home)
        case .missing, .trustFailure:
            let executable = fixtureRoot.appendingPathComponent("fake-codex")
            try Self.writeFakeCodex(
                to: executable,
                home: home,
                hooksURL: hooksURL,
                configURL: config,
                stateURL: fixtureRoot.appendingPathComponent("native-state.json"),
                trustFailure: nativeMode == .trustFailure
            )
            native = CodexNativeHookClient(executable: executable, userHome: home)
        }
    }

    func close() {
        broker.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private static func writeOtherHookDocument(to url: URL) throws {
        let existing: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": "existing",
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/bin/true"
                    ]]
                ]]
            ],
            "keep": true
        ]
        let data = try JSONSerialization.data(withJSONObject: existing, options: [.sortedKeys])
        try data.write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private static func writeFakeCodex(
        to executable: URL,
        home: URL,
        hooksURL: URL,
        configURL: URL,
        stateURL: URL,
        trustFailure: Bool
    ) throws {
        let homeLiteral = String(reflecting: home.path)
        let hooksLiteral = String(reflecting: hooksURL.path)
        let configLiteral = String(reflecting: configURL.path)
        let stateLiteral = String(reflecting: stateURL.path)
        let trustFailureLiteral = trustFailure ? "True" : "False"
        let script = """
        #!/usr/bin/python3
        import json
        import pathlib
        import sys

        home = \(homeLiteral)
        hooks = pathlib.Path(\(hooksLiteral))
        config = \(configLiteral)
        state_path = pathlib.Path(\(stateLiteral))
        trust_failure = \(trustFailureLiteral)
        current_hash = "sha256:" + "a" * 64

        def state():
            if state_path.exists():
                return json.loads(state_path.read_text())
            return {"enabled": False, "trusted": "untrusted"}

        def save(value):
            state_path.write_text(json.dumps(value))

        def own_index():
            try:
                document = json.loads(hooks.read_text())
            except Exception:
                return None
            groups = document.get("hooks", {}).get("PreToolUse", [])
            for index, group in enumerate(groups):
                for handler in group.get("hooks", []):
                    if handler.get("server") == "askkey" and handler.get("tool") == "credential_discovery_guard":
                        return index
            return None

        def metadata():
            index = own_index()
            if index is None:
                return []
            value = state()
            return [{
                "key": str(hooks) + ":pre_tool_use:" + str(index) + ":0",
                "currentHash": current_hash,
                "enabled": value["enabled"],
                "eventName": "preToolUse",
                "isManaged": False,
                "matcher": "^(Bash|mcp__askkey__list_credentials)$",
                "source": "user",
                "sourcePath": str(hooks),
                "timeoutSec": 3,
                "trustStatus": value["trusted"],
                "handlerType": "mcpTool",
                "server": "askkey",
                "tool": "credential_discovery_guard",
                "displayOrder": index
            }]

        def config_read():
            return {
                "layers": [{
                    "name": {"type": "user", "file": config},
                    "version": "fixture-version-1",
                    "config": {"unrelated": "keep"}
                }]
            }

        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"codexHome": home + "/.codex"}
            elif method == "hooks/list":
                result = {"data": [{"cwd": home, "errors": [], "hooks": metadata(), "warnings": []}]}
            elif method == "config/read":
                result = config_read()
            elif method == "config/batchWrite":
                if trust_failure:
                    save({"enabled": False, "trusted": "untrusted"})
                else:
                    save({"enabled": True, "trusted": "trusted"})
                result = {}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
    }
}
