"""Shared event logging, hashing and process utilities for command-hook probes."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import time
from typing import Any, Iterable

from probe_io import stop_owned_process_group



try:
    import fcntl
except ImportError:  # pragma: no cover - command hooks are POSIX clients.
    fcntl = None


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
        if key not in secret_names and not key.endswith("_TOKEN") and not key.startswith("ASKKEY_")
    }
    environment["PATH"] = inherited.get("PATH", "/usr/bin:/bin")
    environment["LC_ALL"] = "C"
    environment["ASKKEY_DEBUG_RUN_DIRECTORY"] = str(debug_state.resolve())
    environment["ASKKEY_BROKER_SOCKET"] = str(missing_broker.resolve())
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
