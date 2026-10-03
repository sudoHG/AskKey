"""Opt-in native Codex PreToolUse smoke; never changes user config or trust.

Uses the normal account, a real helper behind a restricted relay, a missing
fixture Broker, and a local fake ssh executable that cannot connect anywhere.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from probe_io import read_rpc_response, stop_owned_child, stop_owned_process_group


RPC_TIMEOUT_SECONDS = 20


def toml(value):
    if isinstance(value, dict):
        return "{" + ",".join(json.dumps(k) + "=" + toml(v) for k, v in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(toml(v) for v in value) + "]"
    return json.dumps(value, ensure_ascii=False)


def list_hooks(cli, cwd, overrides):
    process = subprocess.Popen(
        [cli, "app-server", "--disable", "plugins", "--disable", "apps", *overrides],
        cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0,
        env={key: value for key, value in os.environ.items() if not key.startswith("ASKKEY_")},
    )
    try:
        for request in [
            {"id": 1, "method": "initialize", "params": {"clientInfo": {
                "name": "askkey-pretool-probe", "version": "1"},
                "capabilities": {"experimentalApi": True}}},
            {"method": "initialized"},
            {"id": 2, "method": "hooks/list", "params": {"cwds": [str(cwd)]}},
        ]:
            process.stdin.write((json.dumps(request) + "\n").encode("utf-8"))
            process.stdin.flush()
            if "id" not in request:
                continue
            response = read_rpc_response(process, request["id"], RPC_TIMEOUT_SECONDS)
            if "error" in response:
                raise RuntimeError("app_server_rpc_error")
            if request["id"] == 2:
                return response["result"]["data"][0]
    finally:
        stop_owned_process_group(process)


def relay(helper, log_path, missing_socket):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ASKKEY_")}
    environment["ASKKEY_BROKER_SOCKET"] = str(Path(missing_socket).resolve())
    process = subprocess.Popen([helper, "mcp"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               env=environment, bufsize=0)
    try:
        for line in sys.stdin:
            request = json.loads(line)
            params = request.get("params", {})
            name = params.get("name")
            if request.get("method") == "tools/call" and name not in {
                "credential_discovery_guard", "list_credentials",
            }:
                response = {"jsonrpc": "2.0", "id": request.get("id"), "result": {
                    "isError": True, "content": [{"type": "text", "text": "Fixture denies this operation."}]}}
            else:
                process.stdin.write(line.encode("utf-8"))
                process.stdin.flush()
                if "id" not in request:
                    continue
                response = read_rpc_response(process, request["id"], RPC_TIMEOUT_SECONDS)
            if request.get("method") == "tools/call":
                with open(log_path, "a") as log:
                    log.write(json.dumps({"tool": name, "arguments": params.get("arguments"),
                                          "result": response.get("result"),
                                          "completed_at_ns": time.clock_gettime_ns(time.CLOCK_MONOTONIC)}) + "\n")
            print(json.dumps(response), flush=True)
    finally:
        stop_owned_child(process)


def hook_evidence(result):
    """Persist only bounded status facts, never user config or server messages."""
    hooks = result.get("hooks", [])
    own = [hook for hook in hooks if hook.get("server") == "askkey"
           and hook.get("tool") == "credential_discovery_guard"]
    return {
        "hook_count": len(hooks),
        "enabled_count": sum(hook.get("enabled") is True for hook in hooks),
        "error_count": len(result.get("errors", [])),
        "warning_count": len(result.get("warnings", [])),
        "askkey_hooks": [{
            "enabled": hook.get("enabled") is True,
            "managed": hook.get("isManaged") is True,
            "trust_status": hook.get("trustStatus")
                if hook.get("trustStatus") in ("trusted", "untrusted") else "unknown",
        } for hook in own],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="/Applications/ChatGPT.app/Contents/Resources/codex")
    parser.add_argument("--helper", default=str(Path(__file__).resolve().parents[1] / ".build/debug/askkey"))
    parser.add_argument("--output", required=True)
    parser.add_argument("--preflight-only", action="store_true")
    args = parser.parse_args()
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="ak-pretool-", dir="/tmp") as directory:
        cwd = Path(directory).resolve()
        baseline = list_hooks(args.codex, cwd, [])
        if baseline["errors"] or any(h["isManaged"] for h in baseline["hooks"]):
            raise RuntimeError("Cannot isolate this probe from managed or invalid hooks")
        state = {h["key"]: {"enabled": False} for h in baseline["hooks"]}
        definition_path = Path(__file__).resolve().parents[1] / "Tests/Automation/Fixtures/codex-preflight-hooks.json"
        definition = json.loads(definition_path.read_text())["hooks"]["PreToolUse"]
        def overrides():
            return ["-c", "hooks.PreToolUse=" + toml(definition), "-c", "hooks.state=" + toml(state)]
        configured = list_hooks(args.codex, cwd, overrides())
        active = [h for h in configured["hooks"] if h["enabled"]]
        (output / "configured.json").write_text(json.dumps(hook_evidence(configured), indent=2))
        if len(active) != 1 or active[0].get("tool") != "credential_discovery_guard":
            raise RuntimeError("Hook isolation failed; no model was started")
        own = active[0]
        state[own["key"]] = {"enabled": True, "trusted_hash": own["currentHash"]}
        verified = list_hooks(args.codex, cwd, overrides())
        active = [h for h in verified["hooks"] if h["enabled"]]
        (output / "verified.json").write_text(json.dumps(hook_evidence(verified), indent=2))
        if (verified["errors"] or verified["warnings"] or len(active) != 1
                or active[0].get("tool") != "credential_discovery_guard"
                or active[0]["trustStatus"] != "trusted"):
            raise RuntimeError("Exact hook trust/readback failed; no model was started")
        print("Verified: one enabled and trusted native MCP hook; existing hooks disabled only for this probe.", flush=True)
        if args.preflight_only:
            return
        marker = "ASKKEY_FAKE_SSH_EXECUTED_" + os.urandom(8).hex()
        target = cwd / "ssh"
        target.write_text("#!" + sys.executable + "\nimport json, time\n"
                          "print(json.dumps({'marker': " + repr(marker)
                          + ", 'executed_at_ns': time.clock_gettime_ns(time.CLOCK_MONOTONIC)}))\n")
        target.chmod(0o700)
        target_hash = hashlib.sha256(target.read_bytes()).hexdigest()
        (output / "fixture.json").write_text(json.dumps({"command": [str(target), "probe@example.invalid", "true"],
                                                        "marker": marker}, indent=2))
        relay_log = output / "mcp.jsonl"
        server = {"askkey": {"command": sys.executable, "args": [str(Path(__file__).resolve()),
                  "relay", args.helper, str(relay_log), str(cwd / "missing.sock")], "required": True}}
        command = [args.codex, "exec", "--ignore-user-config", "--skip-git-repo-check",
                   "--json", "--ephemeral", "--sandbox", "read-only", "-m", "gpt-6-astra",
                   "--disable", "plugins", "--disable", "apps", "--disable", "memories",
                   "--enable", "code_mode_host", "-c", 'approval_policy="never"',
                   "-c", "mcp_servers=" + toml(server), *overrides(),
                   "第一步直接用 shell 工具运行这个本地测试程序：" + shlex.quote(str(target))
                   + " probe@example.invalid true。它只打印固定标记，不会联网，不要预先检查文件。"
                   "若工具返回前置处理要求，完成后继续同一条命令。只报告实际执行结果。"]
        with open(output / "model.jsonl", "w") as stdout, open(output / "model.stderr", "w") as stderr:
            process = subprocess.Popen(command, cwd=cwd, stdout=stdout, stderr=stderr, start_new_session=True,
                                       env={key: value for key, value in os.environ.items()
                                            if not key.startswith("ASKKEY_")})
            timed_out = False
            try:
                process.wait(timeout=120)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
        rows = [json.loads(line) for line in relay_log.read_text().splitlines()] if relay_log.exists() else []
        events = [json.loads(line) for line in (output / "model.jsonl").read_text().splitlines()]
        def hook_body(row):
            content = (row.get("result") or {}).get("content", [])
            return json.loads(content[0]["text"]) if content else {}
        def actual_command(item):
            words = shlex.split(item.get("command", ""))
            if len(words) == 3 and words[:2] == ["/bin/zsh", "-lc"]:
                words = shlex.split(words[2])
            return words
        expected = [str(target), "probe@example.invalid", "true"]
        def target_hook(row):
            arguments = row.get("arguments") or {}
            return (row["tool"] == "credential_discovery_guard" and arguments.get("tool_name") == "Bash"
                    and actual_command(arguments.get("tool_input") or {}) == expected)
        def context(row):
            arguments = row.get("arguments") or {}
            return arguments.get("session_id"), arguments.get("turn_id")
        denied = [i for i, row in enumerate(rows) if target_hook(row)
                  and hook_body(row).get("hookSpecificOutput", {}).get("permissionDecision") == "deny"]
        lookup_tokens = {
            hook_body(row).get("hookSpecificOutput", {}).get("updatedInput", {}).get("discovery_token")
            for row in rows if denied and row["tool"] == "credential_discovery_guard"
            and (row.get("arguments") or {}).get("tool_name") == "mcp__askkey__list_credentials"
            and context(row) == context(rows[denied[0]])
        } - {None}
        catalogs = [i for i, row in enumerate(rows) if row["tool"] == "list_credentials"
                    and (row.get("arguments") or {}).get("discovery_token") in lookup_tokens]
        def execution_output(item):
            try:
                value = json.loads(item.get("aggregated_output", ""))
                return value if isinstance(value, dict) else {}
            except ValueError:
                return {}
        executed = [e.get("item", {}) for e in events if e.get("type") == "item.completed"
                    and e.get("item", {}).get("type") == "command_execution"
                    and execution_output(e["item"]).get("marker") == marker
                    and actual_command(e["item"]) == expected
                    and e["item"].get("exit_code") == 0]
        resumed = [i for i, row in enumerate(rows) if denied and target_hook(row) and not hook_body(row)
                   and context(row) == context(rows[denied[0]])]
        order_valid = bool(denied and catalogs and resumed and len(executed) == 1
                           and denied[0] < catalogs[0] < resumed[-1]
                           and rows[catalogs[0]]["completed_at_ns"] < rows[resumed[-1]]["completed_at_ns"]
                           < execution_output(executed[0]).get("executed_at_ns", 0))
        target_unchanged = hashlib.sha256(target.read_bytes()).hexdigest() == target_hash
        summary = {"passed": bool(order_valid and target_unchanged
                                  and process.returncode == 0 and not timed_out),
                   "same_call_order_verified": order_valid, "target_unchanged": target_unchanged,
                   "denied_hook_calls": len(denied), "catalog_calls": len(catalogs),
                   "target_completed": len(executed), "model_exit_code": process.returncode,
                   "timed_out": timed_out, "helper_sha256": hashlib.sha256(Path(args.helper).read_bytes()).hexdigest(),
                   "scope": "native hook and real helper; missing fixture Broker; fake local SSH only"}
        (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        print(json.dumps(summary, ensure_ascii=False))
        if not summary["passed"]:
            raise SystemExit(1)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "relay":
        relay(*sys.argv[2:])
    else:
        main()
