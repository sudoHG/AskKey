"""Run validation and client execution for isolated command-hook probes."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
from typing import Any

from command_hook_probe_common import (
    MODEL_TIMEOUT_SECONDS, ProbeBlocked, ProbeFailure, _hmac, _json_bytes,
    _kill_process_group, _write_json,
)


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
