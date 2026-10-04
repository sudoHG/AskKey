import Foundation
import XCTest
import AskKeyBroker
import AskKeyIntegrations
import AskKeySystem
@testable import AskKeyAppKit

final class ClaudeCodeOnboardingTests: AskKeyAppTestCase {
    func testClaudeCodeIsFirstAndUsesItsOwnDiscoveryConfiguration() throws {
        XCTAssertEqual(AgentClient.allCases, [.claudeCode, .codex, .cursor, .grok])
        XCTAssertEqual(AgentClient.claudeCode.rawValue, "Claude Code")
        let fixture = try ClaudeOnboardingFixture()
        let context = try fixture.connector.commandDiscoveryContext(for: .claudeCode)
        XCTAssertEqual(context.client, .claude)
        XCTAssertEqual(try fixture.connector.claudeAdapter().homeDirectory, fixture.home)
        XCTAssertEqual(try fixture.connector.claudeAdapter().workingDirectory, fixture.home)
    }

    func testCheckPreviewApplyAndRecheckConfigureBothIntegrations() throws {
        let fixture = try ClaudeOnboardingFixture()
        let checked = try fixture.connector.check(.claudeCode)
        XCTAssertEqual(checked.outcome, .notConfigured)
        XCTAssertEqual(checked.discovery, .missing)
        XCTAssertNil(checked.failure)
        XCTAssertEqual(fixture.mutations, [])
        let preview = try fixture.connector.preview(.claudeCode)
        XCTAssertFalse(preview.connected)
        XCTAssertFalse(preview.configurationPresent)
        XCTAssertEqual(preview.discovery, .missing)
        let result = try fixture.connector.apply(.claudeCode, plan: XCTUnwrap(checked.plan))
        XCTAssertEqual(result.outcome, .verifiedConnected)
        XCTAssertEqual(result.changeStatus, .verifiedAndKept)
        XCTAssertEqual(result.discovery, .configured)
        XCTAssertNil(result.failure)
        XCTAssertEqual(fixture.mutations, ["add"])
        let context = try fixture.connector.commandDiscoveryContext(for: .claudeCode)
        XCTAssertTrue(try context.hook.hasExpectedHook())
        let again = try fixture.connector.check(.claudeCode)
        XCTAssertEqual(again.outcome, .verifiedConnected)
        XCTAssertNil(again.plan)
        XCTAssertTrue(try fixture.connector.preview(.claudeCode).connected)
        XCTAssertTrue(try fixture.connector.connect(.claudeCode))
        XCTAssertEqual(fixture.mutations, ["add"])
    }

    func testExistingConnectedMCPRepairsOnlyDiscovery() throws {
        let fixture = try ClaudeOnboardingFixture()
        try fixture.write("state", "matching")
        let checked = try fixture.connector.check(.claudeCode)
        XCTAssertEqual(checked.outcome, .configuredUnverified)
        let plan = try XCTUnwrap(checked.plan)
        XCTAssertTrue(plan.configurationPresent)
        let result = try fixture.connector.apply(.claudeCode, plan: plan)
        XCTAssertEqual(result.outcome, .verifiedConnected)
        XCTAssertEqual(result.discovery, .configured)
        XCTAssertEqual(fixture.mutations, [])
    }

    func testConflictingAndDisconnectedExistingEntriesOfferNoWrite() throws {
        for state in ["different", "project", "disconnected"] {
            let fixture = try ClaudeOnboardingFixture()
            try fixture.write("state", state)
            let result = try fixture.connector.check(.claudeCode)
            XCTAssertNil(result.plan)
            XCTAssertEqual(result.failure, state == "disconnected" ? .verificationFailed : .nameConflict)
            XCTAssertEqual(fixture.mutations, [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooks.path))
        }
    }

    func testChangedHookPlanDoesNotWriteMCP() throws {
        let fixture = try ClaudeOnboardingFixture()
        let plan = try XCTUnwrap(fixture.connector.check(.claudeCode).plan)
        try fixture.installSettings("{\"permissions\":{\"allow\":[]}}")
        let result = try fixture.connector.apply(.claudeCode, plan: plan)
        XCTAssertEqual(result.failure, .planChanged)
        XCTAssertEqual(result.changeStatus, .notWritten)
        XCTAssertEqual(fixture.mutations, [])
    }

    func testFailedConnectionReportsAdaptersRollback() throws {
        for mode in ["disconnect-after-add", "rollback-fail"] {
            let fixture = try ClaudeOnboardingFixture()
            let plan = try XCTUnwrap(fixture.connector.check(.claudeCode).plan)
            try fixture.write("mode", mode)
            let result = try fixture.connector.apply(.claudeCode, plan: plan)
            XCTAssertEqual(result.failure, mode == "rollback-fail" ? .restoreFailed : .verificationFailed)
            XCTAssertEqual(result.changeStatus, mode == "rollback-fail" ? .restoreFailed : .restored)
            XCTAssertEqual(fixture.mutations, ["add", "remove"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.hooks.path))
        }
    }

    func testHookFailureKeepsVerifiedMCP() throws {
        let fixture = try ClaudeOnboardingFixture()
        let plan = try XCTUnwrap(fixture.connector.check(.claudeCode).plan)
        try fixture.write("mode", "hook-race")
        let result = try fixture.connector.apply(.claudeCode, plan: plan)
        XCTAssertEqual(result.outcome, .configuredUnverified)
        XCTAssertEqual(result.changeStatus, .verifiedAndKept)
        XCTAssertEqual(result.failure, .discoverySetupFailed)
        XCTAssertEqual(result.discovery, .unavailable)
        XCTAssertEqual(fixture.mutations, ["add"])
        XCTAssertTrue(try fixture.connector.claudeAdapter().verify().connected)
    }

    func testCancelledCheckDoesNotInvokeCLIOrWrite() throws {
        let fixture = try ClaudeOnboardingFixture()
        XCTAssertThrowsError(try RestrictedProcessCancellation.withValue({ true }) {
            try fixture.connector.check(.claudeCode)
        }) { XCTAssertEqual($0 as? AgentOnboardingFailure, .cancelled) }
        XCTAssertEqual(fixture.mutations, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("calls").path))
    }

    func testClaudeErrorsMapToExistingOnboardingStates() {
        let cases: [(ClaudeCodeMCPError, AgentOnboardingFailure)] = [
            (.missingExecutable, .cliMissing), (.unsupportedVersion, .unsupportedVersion),
            (.unsupportedCLI, .unsupportedVersion), (.unreadableConfiguration, .illegalConfig),
            (.conflictingEntry, .nameConflict), (.conflictingScope, .nameConflict),
            (.configurationChanged, .planChanged), (.addFailed, .verificationFailed),
            (.verificationFailed("helper_contract"), .helperMismatch),
            (.verificationFailed("broker_unhealthy"), .brokerUnavailable),
            (.verificationFailed("client_disconnected"), .verificationFailed),
            (.rollbackFailed(original: "synthetic", cleanup: "synthetic"), .restoreFailed),
            (.cancelled, .cancelled), (.timeout, .timedOut),
            (.outputTooLarge, .communicationFailed), (.processFailed, .communicationFailed),
        ]
        for (error, expected) in cases { XCTAssertEqual(AgentOnboardingFailure.from(error), expected) }
    }
}

private final class ClaudeOnboardingFixture {
    let root: URL
    let home: URL
    let helper: URL
    let hooks: URL

    init() throws {
        root = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("ak-claude-ui-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        helper = root.appendingPathComponent("askkey")
        hooks = home.appendingPathComponent(".claude/settings.json")
        let executable = home.appendingPathComponent(".local/bin/claude")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try write("state", "absent")
        try write("mode", "ok")
        try install(executable, script: """
        #!/bin/sh
        [ "$HOME" = '\(home.path)' ] || exit 90
        [ "$(/bin/pwd -P)" = '\(home.path)' ] || exit 91
        printf '%s\\n' "$*" >> "$HOME/calls"
        if [ "$1" = --version ]; then printf '2.1.282 (Claude Code)\\n'; exit 0; fi
        if [ "$3" = --help ]; then printf 'Usage: claude mcp %s\\n--scope user\\n' "$2"; exit 0; fi
        state=$(cat "$HOME/state")
        mode=$(cat "$HOME/mode")
        case "$2" in
          add-json)
            printf 'add\\n' >> "$HOME/mutations"
            printf matching > "$HOME/state"
            case "$mode" in disconnect-after-add|rollback-fail) printf disconnected > "$HOME/state";; esac
            if [ "$mode" = hook-race ]; then
              mkdir -p "$HOME/.claude"
              printf '{"syntheticConcurrentSetting":true}' > "$HOME/.claude/settings.json"
            fi
            exit 0;;
          remove)
            printf 'remove\\n' >> "$HOME/mutations"
            [ "$mode" = rollback-fail ] && exit 1
            printf absent > "$HOME/state"; exit 0;;
          get)
            [ "$state" = absent ] && { printf 'No MCP server named "askkey".\\n' >&2; exit 1; }
            scope='User config (available in all your projects)'
            [ "$state" = project ] && scope='Project config (shared via .mcp.json)'
            command='\(helper.path)'
            [ "$state" = different ] && command='/synthetic/other'
            status='✔ Connected'
            [ "$state" = disconnected ] && status='✘ Failed to connect'
            printf 'askkey:\\n  Scope: %s\\n  Status: %s\\n  Type: stdio\\n  Command: %s\\n  Args: mcp\\n' "$scope" "$status" "$command"
            exit 0;;
        esac
        exit 64
        """)
        let health = try JSONEncoder().encode(BrokerResponse.success(.health(
            BrokerHealth(version: BrokerProtocolVersion.current, status: "ok")
        )))
        try install(helper, script: """
        #!/bin/sh
        case "$1" in
          hook) printf '%s\\n' '{"protocolVersion":1,"clients":["claude"]}';;
          mcp)
            cat > /dev/null
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"\(AskKeyVersion.current)"}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}';;
          health) printf '%s\\n' '\(String(decoding: health, as: UTF8.self))';;
          *) exit 64;;
        esac
        """)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var connector: AgentClientConnector {
        AgentClientConnector(home: home, supportDirectory: root.appendingPathComponent("support"), helperURL: helper)
    }

    var mutations: [String] {
        ((try? String(contentsOf: home.appendingPathComponent("mutations"), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    func write(_ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: home.appendingPathComponent(name))
    }

    func installSettings(_ value: String) throws {
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: hooks)
    }

    private func install(_ url: URL, script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}
