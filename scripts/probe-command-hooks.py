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

try:
    import fcntl
except ImportError:  # pragma: no cover - command hooks are POSIX clients.
    fcntl = None


SCRIPT = Path(__file__).resolve()
MAX_CAPTURE_BYTES = 256 * 1024
HOOK_TIMEOUT_SECONDS = 8
MCP_TIMEOUT_SECONDS = 12
MODEL_TIMEOUT_SECONDS = 180


class ProbeBlocked(Exception):
    """A known environmental gate prevents a safe real-client run."""

    def __init__(self, reasons: Iterable[str]):
        self.reasons = list(dict.fromkeys(str(reason) for reason in reasons))
        super().__init__("; ".join(self.reasons))


class ProbeFailure(Exception):
    """A probe invariant or local setup operation failed."""


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def _write_bytes(path: Path, data: bytes, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open("wb") as stream:
        stream.write(data)
    path.chmod(mode)


def _write_json(path: Path, value: Any, mode: int = 0o600) -> None:
    _write_bytes(path, json.dumps(value, ensure_ascii=False, sort_keys=True,
                                  indent=2).encode("utf-8") + b"\n", mode)


def _toml(value: Any) -> str:
    """Encode the small TOML value subset used by the Grok fixture."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, dict):
        return "{" + ", ".join(
            json.dumps(str(key), ensure_ascii=False) + " = " + _toml(item)
            for key, item in value.items()
        ) + "}"
    if isinstance(value, list):
        return "[" + ", ".join(_toml(item) for item in value) + "]"
    if isinstance(value, (int, float)):
        return str(value)
    return json.dumps(str(value), ensure_ascii=False)


def _hmac(key: bytes, value: Any) -> str:
    if isinstance(value, bytes):
        payload = value
    elif isinstance(value, str):
        payload = value.encode("utf-8")
    else:
        payload = _json_bytes(value)
    return hmac.new(key, payload, hashlib.sha256).hexdigest()[:32]


def _read_key(path: Path) -> bytes:
    try:
        key = path.read_bytes()
    except OSError as error:
        raise ProbeFailure(f"event_key_unreadable:{error.strerror}") from error
    if len(key) < 16:
        raise ProbeFailure("event_key_too_short")
    return key


def _append_event(path: Path, key: bytes, record: dict[str, Any]) -> int:
    """Append one redacted event with a cross-process sequence number."""
    if fcntl is None:
        raise ProbeFailure("posix_file_lock_unavailable")
    lock_path = path.with_name(path.name + ".lock")
    sequence_path = path.with_name(path.name + ".sequence")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        with os.fdopen(lock_fd, "r+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                sequence = int(sequence_path.read_text(encoding="ascii"))
            except (FileNotFoundError, ValueError):
                sequence = 0
            sequence += 1
            safe_record = dict(record)
            safe_record["sequence"] = sequence
            with path.open("a", encoding="utf-8") as events:
                events.write(json.dumps(safe_record, ensure_ascii=False,
                                        sort_keys=True) + "\n")
                events.flush()
                os.fsync(events.fileno())
            _write_bytes(sequence_path, str(sequence).encode("ascii"), 0o600)
            return sequence
    finally:
        # The file object closes the descriptor and releases flock.
        pass


def _now() -> int:
    return time.time_ns()


def _event_record(key: bytes, *, client: str, phase: str,
                  input_payload: dict[str, Any], permission: str,
                  helper_exit_code: int | None, helper_ok: bool,
                  source: str = "hook", command: str | None = None,
                  input_value: Any = None) -> dict[str, Any]:
    """Build a record without retaining raw IDs, tool names or arguments."""
    tool = input_payload.get("tool_name", input_payload.get("toolName"))
    session = input_payload.get("conversation_id", input_payload.get("sessionId"))
    turn = input_payload.get("generation_id", input_payload.get("promptId"))
    call = input_payload.get("tool_use_id", input_payload.get("toolUseId"))
    record: dict[str, Any] = {
        "kind": source,
        "client": client,
        "phase": phase,
        "permission": permission,
        "tool_hash": _hmac(key, tool) if isinstance(tool, str) else None,
        "session_hash": _hmac(key, session) if isinstance(session, str) else None,
        "turn_hash": _hmac(key, turn) if isinstance(turn, str) else None,
        "call_hash": _hmac(key, call) if isinstance(call, str) else None,
        "input_hash": _hmac(key, input_value) if input_value is not None else None,
        "helper_exit_code": helper_exit_code,
        "helper_ok": bool(helper_ok),
        "recorded_at_ns": _now(),
    }
    if command is not None:
        record["command_hash"] = _hmac(key, command)
    return record


def _safe_environment(*, debug_state: Path, missing_broker: Path,
                      grok_home: Path | None = None) -> dict[str, str]:
    """Construct a child environment without inheriting credential variables."""
    inherited = dict(os.environ)
    secret_names = {
        "XAI_API_KEY", "GROK_API_KEY", "GROK_AUTH_TOKEN", "OPENAI_API_KEY",
        "ASKKEY_BROKER_SOCKET", "ASKKEY_DEBUG_RUN_DIRECTORY",
        "ASKKEY_VAULT_KEY", "ASKKEY_MASTER_KEY",
    }
    environment = {
        key: value for key, value in inherited.items()
        if key not in secret_names and not key.endswith("_TOKEN")
    }
    environment["PATH"] = inherited.get("PATH", "/usr/bin:/bin")
    environment["LC_ALL"] = "C"
    environment["ASKKEY_DEBUG_RUN_DIRECTORY"] = str(debug_state)
    environment["ASKKEY_BROKER_SOCKET"] = str(missing_broker)
    if grok_home is not None:
        environment["GROK_HOME"] = str(grok_home)
        # The real HOME is deliberately preserved.  These child-only
        # switches keep the user's Cursor/Claude compatibility hooks out of
        # this isolated native-Grok run without changing their config.
        environment["GROK_CURSOR_HOOKS_ENABLED"] = "false"
        environment["GROK_CLAUDE_HOOKS_ENABLED"] = "false"
    return environment


def _kill_process_group(process: subprocess.Popen[bytes]) -> None:
    # _capture still needs to drain its pipes after terminating the group.
    stop_owned_process_group(process, close_pipes=False)


def _capture(command: list[str], *, cwd: Path, environment: dict[str, str],
             timeout: float) -> tuple[int | None, bytes, bytes, bool]:
    process = subprocess.Popen(command, cwd=str(cwd), env=environment,
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
        return process.returncode, stdout[:MAX_CAPTURE_BYTES], stderr[:MAX_CAPTURE_BYTES], False
    except subprocess.TimeoutExpired as error:
        _kill_process_group(process)
        try:
            stdout, stderr = process.communicate(timeout=0.5)
        except subprocess.TimeoutExpired as final_error:
            # A descendant may have escaped the owned process group. Do not
            # wait forever for its pipe, or target unowned/reused process IDs.
            stdout = final_error.output or error.output or b""
            stderr = final_error.stderr or error.stderr or b""
        return process.returncode, stdout[:MAX_CAPTURE_BYTES], stderr[:MAX_CAPTURE_BYTES], True
    finally:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def _executable(value: str | None, fallback_names: tuple[str, ...]) -> Path | None:
    candidate = value
    if candidate is None:
        for name in fallback_names:
            candidate = shutil.which(name)
            if candidate:
                break
    if candidate is None:
        return None
    path = Path(candidate).expanduser()
    if not path.is_absolute():
        found = shutil.which(str(path))
        if found:
            path = Path(found)
    try:
        resolved = path.resolve(strict=True)
        mode = resolved.stat().st_mode
    except OSError:
        return None
    if not stat.S_ISREG(mode) or not os.access(resolved, os.X_OK):
        return None
    return resolved


def _phase(payload: dict[str, Any]) -> str:
    value = payload.get("hook_event_name", payload.get("hookEventName", ""))
    return value if isinstance(value, str) else ""


def _permission(response: Any) -> str:
    if not isinstance(response, dict):
        return "unknown"
    direct = response.get("permission", response.get("decision"))
    if isinstance(direct, str):
        return direct.lower()
    nested = response.get("hookSpecificOutput")
    if isinstance(nested, dict):
        decision = nested.get("permissionDecision", nested.get("decision"))
        if isinstance(decision, str):
            return decision.lower()
    return "none" if response == {} else "unknown"


def _command_from_input(payload: dict[str, Any]) -> str | None:
    tool_input = payload.get("tool_input", payload.get("toolInput"))
    if not isinstance(tool_input, dict):
        return None
    value = tool_input.get("command")
    return value if isinstance(value, str) else None


def _argv_from_command(command: str | None) -> list[str] | None:
    if command is None:
        return None
    try:
        words = shlex.split(command)
    except ValueError:
        return None
    if len(words) == 3 and words[:2] in (["/bin/zsh", "-lc"], ["/bin/sh", "-lc"]):
        try:
            return shlex.split(words[2])
        except ValueError:
            return None
    return words


def _mcp_response_permission(response_bytes: bytes) -> tuple[str, Any, bool]:
    try:
        value = json.loads(response_bytes.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "unknown", None, False
    return _permission(value), value, isinstance(value, dict)


def _hook_wrapper(args: argparse.Namespace) -> int:
    """Native command-hook entrypoint; the client supplies stdin event bytes."""
    key = _read_key(Path(args.event_key_file))
    raw = sys.stdin.buffer.read()
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    phase = _phase(payload)
    command = _command_from_input(payload)
    command_shape = _argv_from_command(command)
    input_value = payload.get("tool_input", payload.get("toolInput"))
    helper = Path(args.helper).resolve()
    environment = _safe_environment(
        debug_state=Path(args.debug_state),
        missing_broker=Path(args.missing_broker),
    )
    response = b""
    exit_code: int | None = None
    helper_ok = False
    try:
        process = subprocess.run(
            [str(helper), "hook", args.client], input=raw, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=environment, timeout=HOOK_TIMEOUT_SECONDS,
            cwd=str(Path(args.debug_state).parent), check=False,
        )
        response = process.stdout
        exit_code = process.returncode
        _, parsed, valid = _mcp_response_permission(response)
        helper_ok = process.returncode == 0 and valid and isinstance(parsed, dict)
    except (OSError, subprocess.TimeoutExpired):
        response = b""
    if not helper_ok:
        # Hook failures are fail-open.  This is the client's normal allow shape;
        # it is never presented as a helper decision in the event log.
        response = (b'{"permission":"allow"}\n' if args.client == "cursor" else b"{}\n")
    try:
        permission, _, valid = _mcp_response_permission(response)
        if not valid:
            permission = "unknown"
    except Exception:  # pragma: no cover - defensive logging boundary.
        permission = "unknown"
    event = _event_record(
        key, client=args.client, phase=phase, input_payload=payload,
        permission=permission, helper_exit_code=exit_code, helper_ok=helper_ok,
        command=json.dumps(command_shape, ensure_ascii=False, separators=(",", ":"))
        if command_shape is not None else None,
        input_value=input_value,
    )
    _append_event(Path(args.events), key, event)
    sys.stdout.buffer.write(response)
    if not response.endswith(b"\n"):
        sys.stdout.buffer.write(b"\n")
    sys.stdout.buffer.flush()
    return 0


def _rpc_error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def _restricted_tool_error(request_id: Any) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": {
        "isError": True,
        "content": [{"type": "text", "text": "Isolated smoke relay allows only list_credentials."}],
    }}


def _read_rpc(process: subprocess.Popen[bytes], expected_id: Any,
              timeout: float) -> dict[str, Any]:
    try:
        return read_rpc_response(process, expected_id, timeout, MAX_CAPTURE_BYTES)
    except (TimeoutError, RPCReadError):
        raise ProbeFailure("mcp_relay_response_timeout") from None


def _sanitize_initialize(response: dict[str, Any]) -> dict[str, Any]:
    sanitized = json.loads(json.dumps(response))
    result = sanitized.get("result")
    if isinstance(result, dict) and "instructions" in result:
        result["instructions"] = "Isolated smoke: only list_credentials is exposed."
    return sanitized


def _filter_tools(response: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    sanitized = json.loads(json.dumps(response))
    result = sanitized.get("result")
    if not isinstance(result, dict) or not isinstance(result.get("tools"), list):
        return sanitized, []
    visible = [tool for tool in result["tools"]
               if isinstance(tool, dict) and tool.get("name") == "list_credentials"]
    result["tools"] = visible
    return sanitized, [str(tool["name"]) for tool in visible]


def _helper_mcp(helper: Path, *, cwd: Path, debug_state: Path,
                missing_broker: Path) -> subprocess.Popen[bytes]:
    environment = _safe_environment(debug_state=debug_state, missing_broker=missing_broker)
    return subprocess.Popen(
        [str(helper), "mcp"], cwd=str(cwd), env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0,
    )


def _relay(args: argparse.Namespace) -> int:
    key = _read_key(Path(args.event_key_file))
    events_path = Path(args.events)
    helper = Path(args.helper).resolve()
    debug_state = Path(args.debug_state).resolve()
    missing_broker = Path(args.missing_broker).resolve()
    cwd = debug_state.parent
    helper_process = _helper_mcp(helper, cwd=cwd, debug_state=debug_state,
                                 missing_broker=missing_broker)
    sequence = 0
    try:
        for raw_line in sys.stdin.buffer:
            if len(raw_line) > MAX_CAPTURE_BYTES:
                if raw_line.strip():
                    response = _rpc_error(None, -32600, "Request exceeds relay size limit")
                    sys.stdout.write(json.dumps(response) + "\n")
                    sys.stdout.flush()
                continue
            try:
                request = json.loads(raw_line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                sys.stdout.write(json.dumps(_rpc_error(None, -32700, "Parse error")) + "\n")
                sys.stdout.flush()
                continue
            if not isinstance(request, dict):
                sys.stdout.write(json.dumps(_rpc_error(None, -32600, "Invalid Request")) + "\n")
                sys.stdout.flush()
                continue
            request_id = request.get("id")
            method = request.get("method")
            if not isinstance(method, str):
                if "id" in request:
                    sys.stdout.write(json.dumps(_rpc_error(request_id, -32600, "Invalid Request")) + "\n")
                    sys.stdout.flush()
                continue
            # Notifications are forwarded without manufacturing a response.
            if "id" not in request:
                if helper_process.stdin is not None:
                    helper_process.stdin.write(raw_line)
                    helper_process.stdin.flush()
                continue
            params = request.get("params")
            params = params if isinstance(params, dict) else {}
            tool_name = params.get("name") if isinstance(params.get("name"), str) else None
            if method == "tools/call" and tool_name != "list_credentials":
                response = _restricted_tool_error(request_id)
            elif method not in {"initialize", "tools/list", "tools/call", "ping"}:
                response = _rpc_error(request_id, -32601, "Method not found")
            else:
                if helper_process.stdin is None:
                    response = _rpc_error(request_id, -32603, "Relay helper unavailable")
                else:
                    helper_process.stdin.write(raw_line)
                    helper_process.stdin.flush()
                    response = _read_rpc(helper_process, request_id, MCP_TIMEOUT_SECONDS)
                    if method == "initialize":
                        response = _sanitize_initialize(response)
                    elif method == "tools/list":
                        response, _ = _filter_tools(response)
            if method == "tools/call":
                result = response.get("result") if isinstance(response, dict) else None
                has_error = bool(response.get("error")) if isinstance(response, dict) else True
                if isinstance(result, dict) and result.get("isError") is True:
                    has_error = True
                sequence = _append_event(events_path, key, {
                    "kind": "mcp_call",
                    "phase": "mcp",
                    "tool_hash": _hmac(key, tool_name) if isinstance(tool_name, str) else None,
                    "request_id_hash": _hmac(key, request_id),
                    "argument_keys": sorted(str(k) for k in (params.get("arguments") or {}).keys())
                    if isinstance(params.get("arguments"), dict) else [],
                    "result": "error" if has_error else "ok",
                    "recorded_at_ns": _now(),
                })
            sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    except (BrokenPipeError, ProbeFailure, OSError):
        return 1
    finally:
        stop_owned_child(helper_process)
    return 0


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


def _phase_is(phase: Any, kind: str) -> bool:
    normalized = str(phase).lower().replace("_", "")
    if kind == "pre":
        return normalized == "pretooluse"
    if kind == "post":
        return normalized in {"posttooluse", "posttoolusefailure"}
    if kind == "prompt":
        return normalized == "userpromptsubmit"
    return False


def _load_events(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and isinstance(value.get("sequence"), int):
            rows.append(value)
    return sorted(rows, key=lambda row: row["sequence"])


def _validate_run(ctx: dict[str, Any], client: str, process_code: int | None,
                  timed_out: bool) -> dict[str, Any]:
    key = ctx["key_file"].read_bytes()
    rows = _load_events(ctx["events"])
    shell_hash = _hmac(key, "Shell" if client == "cursor" else "run_terminal_command")
    catalog_hash = _hmac(key, "MCP:list_credentials" if client == "cursor" else "askkey__list_credentials")
    expected_command_hash = _hmac(key, _json_bytes(ctx["expected_command"]).decode("utf-8"))
    # The wrapper hashes the canonical argv JSON.  Keep the equivalent value
    # above in one place and accept only an exact command shape.
    shell_rows = [row for row in rows if row.get("kind") == "hook"
                  and row.get("tool_hash") == shell_hash
                  and row.get("command_hash") == expected_command_hash]
    denied = [row for row in shell_rows if _phase_is(row.get("phase"), "pre")
              and row.get("permission") == "deny" and row.get("helper_ok")]
    resumed = [row for row in shell_rows if _phase_is(row.get("phase"), "pre")
               and row.get("permission") in {"allow", "none"} and row.get("helper_ok")]
    catalog_hooks = [row for row in rows if row.get("kind") == "hook"
                     and row.get("tool_hash") == catalog_hash]
    catalog_pre = [row for row in catalog_hooks if _phase_is(row.get("phase"), "pre")]
    catalog_done = [row for row in catalog_hooks if _phase_is(row.get("phase"), "post")]
    catalog_mcp = [row for row in rows if row.get("kind") == "mcp_call"
                   and row.get("tool_hash") == _hmac(key, "list_credentials")]

    def context(row: dict[str, Any]) -> tuple[Any, ...] | None:
        session = row.get("session_hash")
        if not isinstance(session, str):
            return None
        if client == "cursor":
            turn = row.get("turn_hash")
            return (session, turn) if isinstance(turn, str) else None
        # Grok tool events have no promptId.  Derive a local turn number from
        # the preceding UserPromptSubmit event for this session; no raw ID is
        # retained in the log.
        current: dict[str, int] = {}
        turn_counter = 0
        for item in rows:
            item_session = item.get("session_hash")
            if not isinstance(item_session, str):
                continue
            if _phase_is(item.get("phase"), "prompt"):
                turn_counter += 1
                current[item_session] = turn_counter
            if item.get("sequence") == row.get("sequence"):
                break
        return (session, current.get(session)) if session in current else None

    denied_one = denied[0] if denied else None
    order_valid = False
    same_context_verified = False
    selected_catalog: dict[str, Any] | None = None
    selected_resume: dict[str, Any] | None = None
    if denied_one is not None:
        denied_context = context(denied_one)
        if denied_context is not None:
            matching_pre = [row for row in catalog_pre if context(row) == denied_context
                            and row["sequence"] > denied_one["sequence"]]
            for pre in matching_pre:
                completions = [row for row in catalog_done
                               if row.get("call_hash") == pre.get("call_hash")
                               and context(row) == denied_context
                               and row["sequence"] > pre["sequence"]]
                mcp_done = [row for row in catalog_mcp
                            if pre["sequence"] < row["sequence"] < (completions[0]["sequence"] if completions else 0)]
                resumes = [row for row in resumed if context(row) == denied_context
                           and row["sequence"] > (completions[0]["sequence"] if completions else 0)]
                if completions and mcp_done and resumes:
                    selected_catalog = completions[0]
                    selected_resume = resumes[0]
                    same_context_verified = True
                    order_valid = (denied_one["sequence"] < pre["sequence"]
                                   < mcp_done[0]["sequence"]
                                   < completions[0]["sequence"]
                                   < resumes[0]["sequence"])
                    break

    marker_text = ""
    stdout_path = ctx.get("model_stdout")
    if isinstance(stdout_path, Path) and stdout_path.exists():
        marker_text = stdout_path.read_text(encoding="utf-8", errors="replace")
    marker_count = marker_text.count(ctx["marker"])
    target_unchanged = hashlib.sha256(ctx["fake_ssh"].read_bytes()).hexdigest() == ctx["target_sha256"]
    passed = bool(order_valid and same_context_verified and marker_count == 1
                  and target_unchanged and process_code == 0 and not timed_out)
    return {
        "passed": passed,
        "acceptance_complete": passed,
        "blocked": False,
        "model_started": True,
        "same_call_order_verified": order_valid,
        "same_turn_verified": same_context_verified,
        "denied_first_exact_ssh": len(denied),
        "catalog_hook_pre_calls": len(catalog_pre),
        "catalog_hook_completed_calls": len(catalog_done),
        "catalog_relay_completed_calls": len(catalog_mcp),
        "resumed_exact_ssh": len(resumed),
        "fake_marker_count": marker_count,
        "target_unchanged": target_unchanged,
        "model_exit_code": process_code,
        "timed_out": timed_out,
        "selected_catalog_completion_sequence": selected_catalog.get("sequence") if selected_catalog else None,
        "selected_resume_sequence": selected_resume.get("sequence") if selected_resume else None,
        "acceptance": "first exact SSH denied -> list_credentials completes -> same-turn exact SSH marker",
    }


def _run_client(args: argparse.Namespace, ctx: dict[str, Any]) -> dict[str, Any]:
    if args.client == "grok":
        raise ProbeBlocked(["grok_isolated_home_login_not_provided_model_not_started"])
    prompt = (
        "Run the exact local command below with the shell tool, once, without inspecting the file "
        "or substituting another command:\n"
        + shlex.join(ctx["expected_command"]) + "\n"
        "If the command is denied by a pre-tool hook, stay in this same turn. Call the Ask Key "
        "MCP list_credentials tool exactly once and wait for its result, even if the result is an "
        "error. Then retry the exact command above once. Stop after that retry and report only "
        "what actually ran."
    )
    command = [str(ctx["client_executable"]), "--print", "--output-format", "stream-json",
               "--workspace", str(ctx["project"]), "--sandbox", "enabled", prompt]
    stdout_path = Path(args.output) / "model.stdout"
    stderr_path = Path(args.output) / "model.stderr"
    ctx["model_stdout"] = stdout_path
    process = subprocess.Popen(command, cwd=str(ctx["project"]), env=ctx["client_environment"],
                               stdin=subprocess.DEVNULL, stdout=stdout_path.open("wb"),
                               stderr=stderr_path.open("wb"), start_new_session=True)
    timed_out = False
    try:
        process.wait(timeout=MODEL_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        timed_out = True
        _kill_process_group(process)
    finally:
        # The Popen file objects are detached by the process object after wait;
        # close our descriptors where possible to make evidence readable.
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
    summary = _validate_run(ctx, args.client, process.returncode, timed_out)
    _write_json(Path(args.output) / "summary.json", summary)
    return summary


def _make_output(path_value: str) -> Path:
    path = Path(path_value).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    if os.path.lexists(str(path)):
        raise ProbeFailure("output_must_be_new")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    (path / "generated").mkdir(mode=0o700)
    return path.resolve()


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
