#!/usr/bin/env python3
"""Run an isolated native command-hook smoke for Cursor or Grok CLI.

The normal path is deliberately opt-in and starts a real client only after a
read-only preflight.  The preflight creates a temporary project, a temporary
Ask Key debug directory, a local ``ssh`` fixture that cannot connect anywhere,
and a restricted MCP relay which exposes only ``list_credentials``.  It never
changes a user's client configuration, trust store, or HOME. Grok child
processes use a temporary GROK_HOME without copying existing credentials.

The command-hook wrapper forwards the exact event bytes to the real helper and
logs only keyed hashes and protocol metadata.  A run passes only when the real
client produces this sequence in one turn: the first exact fixture command is
denied, ``list_credentials`` completes (including a deliberate Broker error),
and the exact fixture command then produces its marker.  ``inspect`` and
configuration readback never count as acceptance.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any, Iterable

from probe_io import RPCReadError, read_rpc_response, stop_owned_child, stop_owned_process_group

from command_hook_probe_common import (
    MAX_CAPTURE_BYTES, HOOK_TIMEOUT_SECONDS, MCP_TIMEOUT_SECONDS, MODEL_TIMEOUT_SECONDS,
    ProbeBlocked, ProbeFailure, _json_bytes, _write_bytes,
    _write_json, _toml, _hmac, _read_key,
    _append_event, _now, _event_record, _safe_environment,
    _kill_process_group, _capture, _executable, fcntl,
)

from command_hook_probe_wrapper import (
    _phase, _permission, _command_from_input, _argv_from_command,
    _mcp_response_permission, _hook_wrapper,
)

from command_hook_probe_relay import (
    _rpc_error, _restricted_tool_error, _read_rpc, _sanitize_initialize,
    _filter_tools, _helper_mcp, _relay,
)

from command_hook_probe_run import (
    _phase_is, _load_events, _validate_run, _run_client,
    _make_output,
)


SCRIPT = Path(__file__).resolve()


def _temp_parent() -> str | None:
    for candidate in (Path("/private/tmp"), Path(tempfile.gettempdir())):
        try:
            if candidate.is_dir() and not candidate.is_symlink():
                return str(candidate)
        except OSError:
            continue
    return None


def _mkdir_private(path: Path) -> None:
    path.mkdir(mode=0o700, parents=False, exist_ok=False)
    path.chmod(0o700)


def _cursor_hooks(command: str) -> dict[str, Any]:
    return {"version": 1, "hooks": {
        "preToolUse": [{"matcher": "Shell|MCP:.*", "command": command, "timeout": 3}],
        "postToolUse": [{"matcher": "Shell|MCP:.*", "command": command, "timeout": 3}],
        "postToolUseFailure": [{"matcher": "Shell|MCP:.*", "command": command, "timeout": 3}],
    }}


def _grok_hooks(command: str) -> dict[str, Any]:
    handler = {"type": "command", "command": command, "timeout": 3}
    tool_handler = {"matcher": "^(run_terminal_command|askkey__list_credentials)$",
                    "hooks": [handler]}
    return {"hooks": {
        "UserPromptSubmit": [{"hooks": [handler]}],
        "PreToolUse": [tool_handler],
        "PostToolUse": [tool_handler],
        "PostToolUseFailure": [tool_handler],
    }}


def _prepare(args: argparse.Namespace, output: Path, root: Path) -> dict[str, Any]:
    project = root / "project"
    debug_state = root / "debug-state"
    grok_home = root / "grok-home"
    for path in (project, debug_state, grok_home):
        _mkdir_private(path)
    (project / ".cursor").mkdir(mode=0o700)
    (project / ".grok").mkdir(mode=0o700)
    (project / ".grok" / "hooks").mkdir(mode=0o700)
    (grok_home / "hooks").mkdir(mode=0o700)

    marker = "ASKKEY_FAKE_SSH_EXECUTED_" + os.urandom(16).hex()
    fake_ssh = project / "ssh"
    _write_bytes(fake_ssh,
                 ("#!/bin/sh\nset -eu\nprintf '%s\\n' " + shlex.quote(marker) + "\n").encode(),
                 0o700)
    expected_command = [str(fake_ssh), "probe@example.invalid", "true"]
    expected_argv_hash = _hmac(Path(args._event_key_file).read_bytes(), expected_command)

    helper = Path(args.helper).expanduser().resolve()
    events = output / "events.jsonl"
    key_file = Path(args._event_key_file).resolve()
    wrapper_arguments = [sys.executable, str(SCRIPT), "wrapper", "--client", args.client,
                         "--helper", str(helper), "--events", str(events),
                         "--event-key-file", str(key_file), "--debug-state", str(debug_state),
                         "--missing-broker", str(root / "missing-broker.sock")]
    relay_arguments = [sys.executable, str(SCRIPT), "relay", "--helper", str(helper),
                       "--events", str(events), "--event-key-file", str(key_file),
                       "--debug-state", str(debug_state), "--missing-broker",
                       str(root / "missing-broker.sock")]
    wrapper_command = shlex.join(wrapper_arguments)

    cursor_hooks = _cursor_hooks(wrapper_command)
    grok_hooks = _grok_hooks(wrapper_command)
    cursor_mcp = {"mcpServers": {"askkey": {
        "command": sys.executable, "args": relay_arguments[1:],
    }}}
    grok_config = "[mcp_servers.askkey]\n" + \
        "command = " + _toml(sys.executable) + "\n" + \
        "args = " + _toml(relay_arguments[1:]) + "\n" + \
        "enabled = true\n" + \
        "startup_timeout_sec = 12\n" + \
        "tool_timeout_sec = 12\n"

    # Cursor's project hook is the active artifact for this temporary project;
    # its global shape is emitted for inspection but never installed globally.
    _write_json(project / ".cursor" / "hooks.json", cursor_hooks)
    _write_json(project / ".cursor" / "mcp.json", cursor_mcp)
    _write_json(output / "generated" / "cursor-project-hooks.json", cursor_hooks)
    _write_json(output / "generated" / "cursor-global-hooks.json", cursor_hooks)
    _write_json(output / "generated" / "cursor-project-mcp.json", cursor_mcp)

    # Grok's global hook is active in a fresh GROK_HOME.  The project hook is
    # emitted and placed in the untrusted project only to validate its native
    # format; no trust flag is passed, so it cannot silently become active.
    _write_json(grok_home / "hooks" / "askkey-discovery.json", grok_hooks)
    _write_json(project / ".grok" / "hooks" / "askkey-discovery.json", grok_hooks)
    _write_json(output / "generated" / "grok-global-hooks.json", grok_hooks)
    _write_json(output / "generated" / "grok-project-hooks.json", grok_hooks)
    _write_bytes(grok_home / "config.toml", grok_config.encode("utf-8"))
    _write_bytes(output / "generated" / "grok-global-config.toml", grok_config.encode("utf-8"))

    _write_json(output / "fixture.json", {
        "command": expected_command,
        "project_relative_command": ["./ssh", "probe@example.invalid", "true"],
        "marker": marker,
        "target_sha256": hashlib.sha256(fake_ssh.read_bytes()).hexdigest(),
        "expected_argv_hash": expected_argv_hash,
        "network": "fake program prints a marker and performs no network operation",
    })
    return {
        "project": project,
        "debug_state": debug_state,
        "grok_home": grok_home,
        "fake_ssh": fake_ssh,
        "marker": marker,
        "expected_command": expected_command,
        "expected_argv_hash": expected_argv_hash,
        "events": events,
        "key_file": key_file,
        "helper": helper,
        "missing_broker": root / "missing-broker.sock",
    }


def _client_version(executable: Path, cwd: Path, environment: dict[str, str]) -> str | None:
    code, stdout, _, timed_out = _capture([str(executable), "--version"], cwd=cwd,
                                          environment=environment, timeout=5)
    if timed_out or code != 0:
        return None
    line = stdout.decode("utf-8", "replace").strip().splitlines()
    return line[0][:160] if line else None


def _cursor_status(executable: Path, cwd: Path, environment: dict[str, str]) -> dict[str, Any]:
    code, stdout, _, timed_out = _capture(
        [str(executable), "status", "--format", "json"], cwd=cwd,
        environment=environment, timeout=8)
    status: dict[str, Any] = {"exit_code": code, "timed_out": timed_out,
                              "json_valid": False, "authenticated": False}
    try:
        value = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        value = None
    if isinstance(value, dict):
        status["json_valid"] = True
        status["authenticated"] = value.get("isAuthenticated") is True or value.get("status") == "authenticated"
    return status


def _path_metadata(path: Path) -> dict[str, Any]:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"present": False}
    kind = "symlink" if stat.S_ISLNK(info.st_mode) else (
        "file" if stat.S_ISREG(info.st_mode) else "directory" if stat.S_ISDIR(info.st_mode) else "other")
    return {"present": True, "kind": kind, "mode": oct(stat.S_IMODE(info.st_mode))}


def _probe_relay(ctx: dict[str, Any], environment: dict[str, str]) -> dict[str, Any]:
    command = [sys.executable, str(SCRIPT), "relay", "--helper", str(ctx["helper"]),
               "--events", str(ctx["events"]), "--event-key-file", str(ctx["key_file"]),
               "--debug-state", str(ctx["debug_state"]), "--missing-broker",
               str(ctx["missing_broker"])]
    process = subprocess.Popen(command, cwd=str(ctx["project"]), env=environment,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, start_new_session=True, bufsize=0)
    try:
        if process.stdin is None:
            raise ProbeFailure("mcp_relay_stdin_unavailable")
        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "askkey-command-hook-probe", "version": "1"},
        }}
        process.stdin.write(_json_bytes(initialize) + b"\n")
        process.stdin.flush()
        initialize_response = _read_rpc(process, 1, MCP_TIMEOUT_SECONDS)
        process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        process.stdin.flush()
        process.stdin.write(b'{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n')
        process.stdin.flush()
        tools_response = _read_rpc(process, 2, MCP_TIMEOUT_SECONDS)
        _, visible = _filter_tools(tools_response)
        return {
            "initialize_ok": isinstance(initialize_response.get("result"), dict),
            "visible_tools": visible,
            "restricted_to_list_credentials": visible == ["list_credentials"],
        }
    finally:
        if process.stdin is not None:
            try:
                process.stdin.close()
            except OSError:
                pass
        _kill_process_group(process)
        if process.stdout is not None:
            process.stdout.close()


def _preflight(args: argparse.Namespace, ctx: dict[str, Any]) -> dict[str, Any]:
    reasons: list[str] = []
    helper = _executable(args.helper, ())
    facts: dict[str, Any] = {
        "client": args.client,
        "helper_path": str(ctx["helper"]),
        "helper_present": helper is not None,
        "model_started": False,
        "forbidden_flags": ["--force", "--yolo", "--trust"],
    }
    if helper is None:
        reasons.append("helper_missing_or_not_executable")
    else:
        environment = _safe_environment(debug_state=ctx["debug_state"],
                                         missing_broker=ctx["missing_broker"])
        code, stdout, _, timed_out = _capture(
            [str(helper), "hook", "capabilities"], cwd=ctx["project"],
            environment=environment, timeout=5)
        capabilities: Any = None
        try:
            capabilities = json.loads(stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            pass
        supported = isinstance(capabilities, dict) and capabilities.get("protocolVersion") == 1 \
            and args.client in capabilities.get("clients", [])
        facts["helper_capabilities"] = {
            "exit_code": code, "timed_out": timed_out, "protocol_version":
            capabilities.get("protocolVersion") if isinstance(capabilities, dict) else None,
            "client_supported": bool(supported),
        }
        if not supported:
            reasons.append("helper_command_hook_capability_missing")

    executable = ctx["client_executable"]
    if executable is None:
        reasons.append(f"{args.client}_cli_missing")
        facts["client_executable"] = None
    else:
        facts["client_executable"] = str(executable)
        client_environment = ctx["client_environment"]
        facts["client_version"] = _client_version(executable, ctx["project"], client_environment)
        if facts["client_version"] is None:
            reasons.append(f"{args.client}_version_unavailable")

    if args.client == "cursor":
        global_hooks = Path.home() / ".cursor" / "hooks.json"
        metadata = _path_metadata(global_hooks)
        facts["cursor_user_global_hooks"] = metadata
        if metadata.get("present"):
            reasons.append("cursor_global_hooks_present_cannot_disable_or_exclude")
        if executable is not None:
            status = _cursor_status(executable, ctx["project"], ctx["client_environment"])
            facts["cursor_status"] = status
            if not status["authenticated"]:
                reasons.append("cursor_login_not_verified")
    else:
        inspect_environment = ctx["client_environment"]
        code, stdout, _, timed_out = _capture(
            [str(executable), "inspect", "--json"] if executable else ["grok", "inspect", "--json"],
            cwd=ctx["project"], environment=inspect_environment, timeout=12)
        try:
            inspect_value = json.loads(stdout.decode("utf-8"))
            inspect_valid = isinstance(inspect_value, (dict, list))
        except (UnicodeDecodeError, json.JSONDecodeError):
            inspect_valid = False
        facts["grok_inspect"] = {
            "exit_code": code, "timed_out": timed_out, "json_valid": inspect_valid,
            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
        }
        if timed_out or code != 0 or not inspect_valid:
            reasons.append("grok_inspect_unavailable_in_isolated_home")
        auth = Path(ctx["grok_home"]) / "auth.json"
        mcp_auth = Path(ctx["grok_home"]) / "mcp_credentials.json"
        facts["grok_isolated_auth_files"] = {
            "auth": _path_metadata(auth), "mcp_credentials": _path_metadata(mcp_auth),
        }
        if auth.exists() or mcp_auth.exists():
            reasons.append("grok_isolated_home_contains_unexpected_auth_file")
        else:
            reasons.append("grok_isolated_home_login_not_provided_model_not_started")

    if helper is not None:
        try:
            relay = _probe_relay(ctx, _safe_environment(
                debug_state=ctx["debug_state"], missing_broker=ctx["missing_broker"],
                grok_home=ctx["grok_home"] if args.client == "grok" else None))
            facts["restricted_relay"] = relay
            if not relay["initialize_ok"] or not relay["restricted_to_list_credentials"]:
                reasons.append("restricted_relay_tool_surface_invalid")
        except (OSError, ProbeFailure) as error:
            facts["restricted_relay"] = {"error": type(error).__name__}
            reasons.append("restricted_relay_handshake_failed")

    facts["passed"] = not reasons
    facts["blocked"] = bool(reasons)
    facts["blocked_reasons"] = reasons
    facts["acceptance"] = "requires real client: first exact SSH denied, catalog completion, same-turn marker"
    _write_json(Path(args.output) / "preflight.json", facts)
    if reasons:
        raise ProbeBlocked(reasons)
    return facts


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", choices=("cursor", "grok"), required=True)
    parser.add_argument("--helper", default=str(SCRIPT.parents[1] / ".build" / "debug" / "askkey"),
                        help="Ask Key helper executable")
    parser.add_argument("--output", required=True,
                        help="new directory for redacted evidence")
    parser.add_argument("--preflight-only", action="store_true",
                        help="generate and inspect the isolated setup without starting a model")
    parser.add_argument("--cursor-agent", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--grok", default=None, help=argparse.SUPPRESS)
    return parser


def _internal_parser(kind: str) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    if kind == "wrapper":
        parser.add_argument("--client", choices=("cursor", "grok"), required=True)
        parser.add_argument("--helper", required=True)
    else:
        parser.add_argument("--helper", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--event-key-file", required=True)
    parser.add_argument("--debug-state", required=True)
    parser.add_argument("--missing-broker", required=True)
    return parser


def _main(argv: list[str]) -> int:
    if argv and argv[0] in {"wrapper", "relay"}:
        parser = _internal_parser(argv[0])
        args = parser.parse_args(argv[1:])
        return _hook_wrapper(args) if argv[0] == "wrapper" else _relay(args)

    args = _build_parser().parse_args(argv)
    output = _make_output(args.output)
    # Keep this key only under the temporary root; wrapper and relay receive a
    # path, never the key itself.  It disappears with the temporary workspace.
    parent = _temp_parent()
    with tempfile.TemporaryDirectory(prefix="askkey-command-hook-", dir=parent) as directory:
        root = Path(directory).resolve()
        root.chmod(0o700)
        key_file = root / "event-key"
        _write_bytes(key_file, os.urandom(32), 0o600)
        args._event_key_file = str(key_file)
        args.output = str(output)
        ctx = _prepare(args, output, root)
        cursor_value = args.cursor_agent or os.environ.get("CURSOR_AGENT")
        grok_value = args.grok or os.environ.get("GROK_CLI")
        ctx["client_executable"] = _executable(
            cursor_value if args.client == "cursor" else grok_value,
            ("cursor-agent",) if args.client == "cursor" else ("grok",),
        )
        ctx["target_sha256"] = hashlib.sha256(ctx["fake_ssh"].read_bytes()).hexdigest()
        if args.client == "grok":
            ctx["client_environment"] = _safe_environment(
                debug_state=ctx["debug_state"], missing_broker=ctx["missing_broker"],
                grok_home=ctx["grok_home"],
            )
        else:
            ctx["client_environment"] = _safe_environment(
                debug_state=ctx["debug_state"], missing_broker=ctx["missing_broker"],
            )
            ctx["client_environment"]["PATH"] = str(ctx["project"]) + os.pathsep + ctx["client_environment"]["PATH"]
        try:
            preflight = _preflight(args, ctx)
        except ProbeBlocked as blocked:
            summary = {
                "passed": False, "acceptance_complete": False, "blocked": True,
                "blocked_reasons": blocked.reasons, "model_started": False,
                "acceptance": "requires real client: first exact SSH denied, catalog completion, same-turn marker",
            }
            _write_json(output / "summary.json", summary)
            print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
            return 2
        except (ProbeFailure, OSError) as error:
            summary = {
                "passed": False, "acceptance_complete": False, "blocked": True,
                "blocked_reasons": [f"probe_setup_failed:{type(error).__name__}"],
                "model_started": False,
            }
            _write_json(output / "summary.json", summary)
            print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
            return 2

        if args.preflight_only:
            # Keep preflight's passed bit separate: it proves only setup and
            # inspection.  The acceptance summary must remain false.
            summary = {
                "passed": False, "preflight_passed": bool(preflight.get("passed")),
                "acceptance_complete": False, "blocked": False,
                "model_started": False,
                "acceptance": "inspect/preflight never counts as real-client acceptance",
            }
            _write_json(output / "summary.json", summary)
            print(json.dumps(preflight, ensure_ascii=False, sort_keys=True))
            return 0
        try:
            summary = _run_client(args, ctx)
        except ProbeBlocked as blocked:
            summary = {"passed": False, "acceptance_complete": False, "blocked": True,
                       "blocked_reasons": blocked.reasons, "model_started": False}
            _write_json(output / "summary.json", summary)
            print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
            return 2
        print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
        return 0 if summary.get("passed") else 1


if __name__ == "__main__":
    try:
        raise SystemExit(_main(sys.argv[1:]))
    except (ProbeFailure, OSError) as error:
        print(json.dumps({"passed": False, "blocked": True,
                          "blocked_reasons": [f"probe_error:{type(error).__name__}"]},
                         ensure_ascii=False), file=sys.stderr)
        raise SystemExit(2)
