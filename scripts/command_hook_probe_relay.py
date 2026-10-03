"""Restricted MCP relay for isolated command-hook probes."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
from typing import Any

from probe_io import RPCReadError, read_rpc_response, stop_owned_child
from command_hook_probe_common import (
    MAX_CAPTURE_BYTES, MCP_TIMEOUT_SECONDS, ProbeFailure, _append_event, _hmac,
    _now, _read_key, _safe_environment,
)


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
