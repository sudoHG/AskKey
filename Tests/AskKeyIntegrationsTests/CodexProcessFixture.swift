import Darwin
import Foundation
import XCTest
@testable import AskKeyUnitTestSupport
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeySystem

struct CodexProcessFixture {
    let executable: URL

    init(harness: CodexUserMCPAdapterTests.Harness, versionOutput: String = "codex-cli 0.154.0") throws {
        executable = harness.root.appendingPathComponent("codex-process-fixture")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let helperLiteral = String(decoding: try encoder.encode(harness.helperURL.path), as: UTF8.self)
        let entry = "[mcp_servers.askkey]\ncommand = \(helperLiteral)\nargs = [\"mcp\"]\n"
        // Fixtures always use a synthetic child; installed CLI acceptance is a separate opt-in test.
        // JSON fields: openai/codex rust-v0.154.0, codex-rs/cli/src/mcp_cmd.rs run_get.
        let server: [String: Any] = [
            "name": "askkey", "enabled": true,
            "transport": ["type": "stdio", "command": harness.helperURL.path, "args": ["mcp"]],
        ]
        let response = String(decoding: try JSONSerialization.data(withJSONObject: server,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let script = """
        #!/bin/sh
        set -eu
        if [ "$#" -eq 1 ] && [ "$1" = '--version' ]; then
            printf '%s\\n' \(codexFixtureShellLiteral(versionOutput))
            exit 0
        fi
        if [ "$*" = 'mcp add --help' ]; then
            printf '%s\\n' 'Usage: codex mcp add [OPTIONS] <NAME> -- <COMMAND>...'
            exit 0
        fi
        case "${CODEX_HOME-}" in
            \(codexFixtureShellLiteral(harness.root.path))/*) ;;
            *) exit 73 ;;
        esac
        [ "${HOME-}" = "$(/usr/bin/dirname "$CODEX_HOME")" ] || exit 73
        if [ "$*" = 'mcp get askkey --json' ]; then
            /usr/bin/grep -q '^\\[mcp_servers\\.askkey\\]$' "$CODEX_HOME/config.toml"
            printf '%s\\n' \(codexFixtureShellLiteral(response))
            exit 0
        fi
        [ "$#" -eq 6 ] && [ "$1" = 'mcp' ] && [ "$2" = 'add' ] && [ "$3" = 'askkey' ] \\
            && [ "$4" = '--' ] && [ "$5" = \(codexFixtureShellLiteral(harness.helperURL.path)) ] \\
            && [ "$6" = 'mcp' ] || exit 64
        /bin/mkdir -p "$CODEX_HOME"
        printf '\\n%s\\n' \(codexFixtureShellLiteral(entry)) >> "$CODEX_HOME/config.toml"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
}

private func codexFixtureShellLiteral(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func scopedCodexOutput(_ executable: URL, arguments: [String], config: URL) throws -> Data {
    let directory = config.deletingLastPathComponent()
    let result = try RestrictedProcess.run(.init(
        executable: executable,
        arguments: arguments,
        // Child-only settings: no process-global or shell HOME/CODEX_HOME mutation, no inherited auth tokens.
        environment: ["PATH": "/usr/bin:/bin", "HOME": directory.deletingLastPathComponent().path,
                      "CODEX_HOME": directory.path],
        currentDirectory: directory.deletingLastPathComponent(),
        timeout: 5,
        usesMonotonicClock: true,
        maximumOutputBytes: 65_536,
        truncateOutput: false
    ))
    guard !result.timedOut, result.status == 0 else { throw CocoaError(.executableRuntimeMismatch) }
    return result.stdout
}
