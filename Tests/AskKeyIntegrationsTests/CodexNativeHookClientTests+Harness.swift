import Darwin
import Foundation
import XCTest
@testable import AskKeyIntegrations

extension CodexNativeHookClientTests {
    final class Harness {
        enum HookState: Equatable {
            case missing
            case disabled
            case untrusted
            case enabled
            case modified
        }

        let root: URL
        let codexDirectory: URL
        let hooksURL: URL
        let configURL: URL
        let executable: URL
        let client: CodexNativeHookClient
        let hookKey: String
        let postHookKey: String
        let currentHash = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let postHash = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        let originalConfig = Data("model = \"fixture\"\n".utf8)
        private let initialTrust: String
        private let requestLog: URL

        init(hookState: HookState, surroundingGroups: Bool = false, onlyEvent: String? = nil, legacy: Bool = false,
             metadataOverrides: [String: [String: Any]] = [:], concurrentHookEdit: Bool = false) throws {
            initialTrust = hookState == .modified ? "modified"
                : ([.disabled, .enabled].contains(hookState) ? "trusted" : "untrusted")
            root = URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent("askkey-native-hook-\(UUID().uuidString)", isDirectory: true)
            codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
            hooksURL = codexDirectory.appendingPathComponent("hooks.json")
            configURL = codexDirectory.appendingPathComponent("config.toml")
            executable = root.appendingPathComponent("codex-fixture")
            let index = surroundingGroups ? 1 : 0
            hookKey = "\(hooksURL.path):pre_tool_use:\(index):0"
            postHookKey = "\(hooksURL.path):post_tool_use:\(index):0"
            requestLog = root.appendingPathComponent("requests.jsonl")
            client = CodexNativeHookClient(executable: executable, userHome: root)

            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
            try writeHooks(state: hookState, surroundingGroups: surroundingGroups, onlyEvent: onlyEvent, legacy: legacy)
            try originalConfig.write(to: configURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            try writeExecutable(enabled: hookState == .enabled, metadataOverrides: metadataOverrides,
                                concurrentHookEdit: concurrentHookEdit)
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

        private func writeHooks(state: HookState, surroundingGroups: Bool, onlyEvent: String?, legacy: Bool) throws {
            let commandHook: [String: Any] = [
                "matcher": "^(Bash|mcp__askkey__list_credentials)$",
                "hooks": [["type": "command", "command": "\"/Applications/Ask Key.app/Contents/Helpers/askkey\" hook codex", "timeout": 3]]
            ]
            let legacyHook: [String: Any] = [
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
            let unrelated: [String: Any] = ["matcher": "unrelated", "hooks": [["type": "command", "command": "true"]]]
            var events: [String: Any] = [:]
            for event in ["PreToolUse", "PostToolUse"] {
                let present = state != .missing && (onlyEvent == nil || onlyEvent == event) && (!legacy || event == "PreToolUse")
                let own = present ? [legacy ? legacyHook : commandHook] : []
                events[event] = surroundingGroups ? [unrelated] + own + [unrelated] : own
            }
            let root: [String: Any] = ["hooks": events]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            try data.write(to: hooksURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hooksURL.path)
        }

        private func writeExecutable(enabled: Bool, metadataOverrides: [String: [String: Any]], concurrentHookEdit: Bool) throws {
            let homeLiteral = String(reflecting: root.path)
            let configLiteral = String(reflecting: configURL.path)
            let hooksLiteral = String(reflecting: hooksURL.path)
            let logLiteral = String(reflecting: requestLog.path)
            let hashLiteral = String(reflecting: currentHash)
            let postHashLiteral = String(reflecting: postHash)
            let initialTrustLiteral = String(reflecting: initialTrust)
            let legacyKeyLiteral = String(reflecting: hookKey)
            let overridesData = try JSONSerialization.data(withJSONObject: metadataOverrides, options: [.sortedKeys])
            let overridesLiteral = String(reflecting: String(decoding: overridesData, as: UTF8.self))
            let script = """
            #!/usr/bin/python3
            import json
            import pathlib
            import sys

            home = \(homeLiteral)
            config = \(configLiteral)
            hooks = \(hooksLiteral)
            log_path = pathlib.Path(\(logLiteral))
            current_hash = \(hashLiteral)
            post_hash = \(postHashLiteral)
            enabled = \(enabled ? "True" : "False")
            trusted = \(initialTrustLiteral)
            overrides = json.loads(\(overridesLiteral))
            concurrent_hook_edit = \(concurrentHookEdit ? "True" : "False")
            trust_state = {"unrelated-disabled": {"enabled": False, "trusted_hash": "keep"},
                           "legacy-mcp-key": {"enabled": False, "trusted_hash": "old"}}
            if trusted == "modified":
                trust_state[\(legacyKeyLiteral)] = {"enabled": False,
                    "trusted_hash": "sha256:de649513d3d2d2d50c5a9747079e3fa5879d89ea2e9fb15238e7923b0efa6c93"}

            pathlib.Path(sys.argv[0]).with_name("argv.json").write_text(json.dumps(sys.argv[1:]))

            def hook(event, event_key, index):
                metadata = {
                    "key": hooks + ":" + event_key + ":" + str(index) + ":0",
                    "currentHash": current_hash if event == "preToolUse" else post_hash,
                    "enabled": enabled,
                    "eventName": event,
                    "isManaged": False,
                    "matcher": "^(Bash|mcp__askkey__list_credentials)$",
                    "source": "user",
                    "sourcePath": hooks,
                    "timeoutSec": 3,
                    "trustStatus": "untrusted" if trusted == "modified" and event == "postToolUse" else trusted,
                    "handlerType": "command",
                    "command": '\"/Applications/Ask Key.app/Contents/Helpers/askkey\" hook codex',
                    "async": False,
                    "displayOrder": 0,
                }
                metadata.update(overrides.get(event, {}))
                return metadata

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
                        "config": {"hooks": {"state": trust_state}},
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
                    document = json.loads(pathlib.Path(hooks).read_text())
                    metadata = []
                    for raw, event, event_key in [("PreToolUse", "preToolUse", "pre_tool_use"),
                                                 ("PostToolUse", "postToolUse", "post_tool_use")]:
                        for index, group in enumerate(document.get("hooks", {}).get(raw, [])):
                            if group.get("hooks", [{}])[0].get("command", "").endswith(" hook codex"):
                                metadata.append(hook(event, event_key, index))
                    result = {"data": [{"cwd": home, "errors": [], "hooks": metadata, "warnings": []}]}
                elif method == "config/read":
                    if concurrent_hook_edit:
                        document = json.loads(pathlib.Path(hooks).read_text())
                        document["keep"] = "concurrent"
                        pathlib.Path(hooks).write_text(json.dumps(document))
                    result = config_read()
                elif method == "config/batchWrite":
                    enabled = True
                    trusted = "trusted"
                    trust_state.update(request["params"]["edits"][0]["value"])
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
