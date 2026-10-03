"""Native command-hook wrapper for isolated command-hook probes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys
from typing import Any

from command_hook_probe_common import (
    HOOK_TIMEOUT_SECONDS, _append_event, _event_record, _read_key, _safe_environment,
)


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
