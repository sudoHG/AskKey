import Foundation
import AskKeyBroker
@testable import AskKeyIntegrations
@testable import AskKeyUnitTestSupport

/// This executable only accesses its synthetic HOME and never invokes Claude.
final class ClaudeCodeMCPFixture {
    let root: URL
    let home: URL
    let project: URL
    let executable: URL
    let helper: URL

    init() throws {
        root = try physicalTestDirectory(FileManager.default.temporaryDirectory)
            .appendingPathComponent("askkey-claude-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        project = root.appendingPathComponent("project")
        executable = home.appendingPathComponent(".local/bin/claude")
        helper = home.appendingPathComponent("Ask Key.app/Contents/Helpers/askkey")
        for url in [project, executable.deletingLastPathComponent(), helper.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try write("state", "absent")
        try write("version", "2.1.282 (Claude Code)")
        try write("mode", "ok")
        try write("helper-mode", "ok")
        try install(executable, script: cliScript)
        try install(helper, script: helperScript)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func adapter(signing: CodexHelperSigning = .development) -> ClaudeCodeMCPAdapter {
        ClaudeCodeMCPAdapter(
            homeDirectory: home, workingDirectory: project, helperURL: helper,
            brokerSocketPath: root.appendingPathComponent("synthetic.sock").path,
            signing: signing, searchPath: "/usr/bin:/bin"
        )
    }

    func write(_ name: String, _ value: String) throws {
        try Data(value.utf8).write(to: home.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
    }

    var mutations: [String] {
        ((try? read("mutations")) ?? "").split(whereSeparator: \.isNewline).map(String.init)
    }

    func install(_ url: URL, script: String) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private var cliScript: String {
        """
        #!/bin/sh
        [ "$HOME" = '\(home.path)' ] || exit 90
        [ "$(/bin/pwd -P)" = '\(project.path)' ] || { printf 'Unexpected cwd: %s\\n' "$(/bin/pwd -P)" >&2; exit 91; }
        [ -z "$CLAUDE_CONFIG_DIR$ANTHROPIC_API_KEY$NODE_OPTIONS$ASKKEY_DEBUG_RUN_DIRECTORY" ] || exit 92
        [ "$LC_ALL" = 'en_US.UTF-8' ] || exit 93
        printf '%s\\n' "$*" >> "$HOME/calls"
        mode=$(cat "$HOME/mode")
        state=$(cat "$HOME/state")
        if [ "$mode" = sleep ]; then sleep 20; fi
        if [ "$mode" = flood ]; then yes output | head -c 2097152; exit 0; fi
        if [ "$1" = --version ]; then cat "$HOME/version"; exit 0; fi
        [ "$1" = mcp ] || exit 64
        if [ "$3" = --help ]; then
          [ "$mode" = unsupported ] && exit 1
          [ "$mode" = "no-$2" ] && exit 1
          if [ "$mode" = no-scope ]; then printf 'Usage: claude mcp %s\\n' "$2"; exit 0; fi
          printf 'Usage: claude mcp %s\\n--scope <scope> user, project, local\\n' "$2"
          exit 0
        fi
        if [ "$2" = add-json ]; then
          [ "$3" = askkey ] && [ "$5" = --scope ] && [ "$6" = user ] && [ "$#" -eq 6 ] || exit 64
          printf '%s' "$4" > "$HOME/added-json"
          printf 'add\\n' >> "$HOME/mutations"
          [ "$mode" = add-fail ] && exit 1
          printf matching > "$HOME/state"
          if [ "$mode" = concurrent-change ]; then printf different > "$HOME/state"; fi
          exit 0
        fi
        if [ "$2" = remove ]; then
          [ "$3" = askkey ] && [ "$4" = --scope ] && [ "$5" = user ] && [ "$#" -eq 5 ] || exit 64
          printf 'remove\\n' >> "$HOME/mutations"
          [ "$mode" = rollback-fail ] && exit 1
          [ "$mode" = rollback-retained ] || printf absent > "$HOME/state"
          exit 0
        fi
        if [ "$2" = list ]; then
          printf 'list-called\\n' >> "$HOME/mutations"
          [ "$mode" = list-fail ] && exit 1
          if [ "$mode" = list-conflict ]; then
            printf '%s\\n' '\(ClaudeCodeMCPOutputSamples.listedServer)'
          elif [ "$mode" = unrelated-server ]; then
            printf 'Checking MCP server health…\\n\\nExternal connector.name: node server.js - ✔ Connected\\n'
          else
            printf '%s\\n' '\(ClaudeCodeMCPOutputSamples.emptyList)'
          fi
          exit 0
        fi
        if [ "$2" = get ]; then
          if [ "$mode" = cancel-after-add ] && [ "$state" = matching ] && [ ! -f "$HOME/cancelled" ]; then
            touch "$HOME/cancelled"
            sleep 20
          fi
          [ "$mode" = get-fail ] && { printf 'Permission denied\\n' >&2; exit 1; }
          if [ "$state" = absent ]; then
            if [ "$mode" = absent-other-servers ]; then
              printf '%s\\n' '\(ClaudeCodeMCPOutputSamples.absentWithServers.replacingOccurrences(of: "askkey", with: "unrelated").replacingOccurrences(of: "nothere", with: "askkey"))'
            else
              printf '%s\\n' '\(ClaudeCodeMCPOutputSamples.absentWithoutServers)' >&2
            fi
            exit 1
          fi
          if [ "$mode" = unreadable ]; then printf 'new output contract\\n'; exit 0; fi
          scope='User config (available in all your projects)'
          [ "$state" = project ] && scope='Project config (shared via .mcp.json)'
          [ "$state" = local ] && scope='Local config (private to you in this project)'
          command='\(helper.path)'
          [ "$state" = different ] && command='/synthetic/other-helper'
          status='✔ Connected'
          [ "$mode" = wrong-status ] && status='✓ Connected'
          case "$mode" in disconnected|rollback-fail|rollback-retained) status='✘ Failed to connect';; esac
          printf 'askkey:\\n  Scope: %s\\n  Status: %s\\n' "$scope" "$status"
          [ "$status" = '✘ Failed to connect' ] && printf '  Issue: CONNECTION_CLOSED: Connection closed\\n'
          [ "$mode" = unknown-field ] && printf '  Future diagnostic: synthetic detail\\n  \\n'
          printf '  Type: stdio\\n  Command: %s\\n  Args: mcp\\n' "$command"
          if [ "$mode" = extra-env ]; then printf '  Environment:\\n    TOKEN=synthetic\\n'; fi
          if [ "$mode" = empty-env ]; then printf '  Environment:\\n'; fi
          if [ "$mode" = env-assignment ]; then printf '  TOKEN=synthetic\\n'; fi
          if [ "$mode" = duplicate-command ]; then printf '  Command: /synthetic/duplicate\\n'; fi
          if [ "$mode" = extra-args ]; then printf '  Args: mcp extra\\n'; fi
          printf '\\nTo remove this server, run: claude mcp remove askkey -s user\\n'
          exit 0
        fi
        exit 64
        """
    }

    private var helperScript: String {
        let health = try! JSONEncoder().encode(BrokerResponse.success(.health(
            BrokerHealth(version: BrokerProtocolVersion.current, status: "ok")
        )))
        return """
        #!/bin/sh
        mode=$(cat "$HOME/helper-mode")
        printf '%s\\n' "$*" >> "$HOME/helper-calls"
        if [ "$1" = mcp ]; then
          cat > "$HOME/requests"
          [ "$mode" = malformed ] && { printf '{}\\n'; exit 0; }
          [ "$mode" = nonzero ] && exit 1
          printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","serverInfo":{"name":"askkey","version":"\(AskKeyVersion.current)"}}}'
          printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"list_credentials"},{"name":"run"}]}}'
          exit 0
        fi
        if [ "$1" = health ]; then
          [ "$mode" = unhealthy ] && exit 1
          printf '%s\\n' '\(String(decoding: health, as: UTF8.self))'
          exit 0
        fi
        exit 64
        """
    }
}
