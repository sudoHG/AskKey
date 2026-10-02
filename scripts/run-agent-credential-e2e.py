"""Opt-in model-driven credential flow against an isolated synthetic Broker.

Uses the real debug helper, Broker runtime and approval state machine. The
fixture replaces the App vault and human authentication; no production vault,
NAS, stored credential, or global client configuration is used.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import tempfile
import time


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--broker", required=True, help="Compiled CredentialDiscoveryBroker fixture")
    parser.add_argument("--helper", default=".build/debug/askkey")
    parser.add_argument("--codex", default="/Applications/ChatGPT.app/Contents/Resources/codex")
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=int, default=150)
    args = parser.parse_args()
    helper = str(Path(args.helper).resolve())
    broker_executable = str(Path(args.broker).resolve())
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    environment = {
        key: value for key, value in os.environ.items()
        if key in {"HOME", "USER", "LOGNAME", "SHELL", "PATH", "TMPDIR", "CODEX_HOME", "LANG"}
        or key.startswith("LC_")
    }
    with tempfile.TemporaryDirectory(prefix="akd-", dir="/tmp") as directory:
        root = Path(directory)
        inspection = root / "inspect-nas"
        # Generated synthetic target; it can only report fixed non-secret facts.
        inspection.write_text(
            '#!/bin/sh\nset -eu\n'
            '[ -n "${NAS_TEST_TOKEN:-}" ] || exit 7\n'
            'printf \'%s\\n\' \'{"ssh_enabled":true,"authorized_key_count":2,"password_authentication_enabled":false}\'\n'
        )
        inspection.chmod(0o700)
        schema = root / "response-schema.json"
        schema.write_text(json.dumps({
            "type": "object", "additionalProperties": False,
            "properties": {
                "ssh_enabled": {"type": ["boolean", "null"]},
                "authorized_key_count": {"type": ["integer", "null"]},
                "password_authentication_enabled": {"type": ["boolean", "null"]},
                "summary": {"type": "string"},
            },
            "required": ["ssh_enabled", "authorized_key_count", "password_authentication_enabled", "summary"],
        }))
        socket_path = str(root / "broker.sock")
        with (output / "broker.log").open("w") as broker_log:
            broker = subprocess.Popen(
                [broker_executable, directory, str(inspection)],
                env=environment, stdout=broker_log, stderr=broker_log, start_new_session=True,
            )
            model = None
            try:
                deadline = time.monotonic() + 10
                while not Path(socket_path).exists():
                    if broker.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("Isolated Broker did not become ready")
                    time.sleep(0.05)
                command = [
                    args.codex, "exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check",
                    "--json", "-m", "gpt-6-astra",
                    "--disable", "apps", "--disable", "memories", "--enable", "skip_host_skill_discovery",
                    "--enable", "network_proxy",
                    "-c", 'default_permissions="askkey-e2e"',
                    "-c", 'permissions.askkey-e2e.extends=":read-only"',
                    "-c", "permissions.askkey-e2e.network.enabled=true",
                    "-c", 'permissions.askkey-e2e.network.mode="limited"',
                    "-c", 'permissions.askkey-e2e.network.unix_sockets={' + json.dumps(str(Path(socket_path).resolve())) + '="allow"}',
                    "-c", 'approval_policy="never"', "-c", "project_doc_max_bytes=0",
                    "-c", f"mcp_servers.askkey.command={json.dumps(helper)}",
                    "-c", 'mcp_servers.askkey.args=["mcp"]',
                    "-c", "mcp_servers.askkey.required=true",
                    "-c", f"mcp_servers.askkey.env.ASKKEY_BROKER_SOCKET={json.dumps(socket_path)}",
                    "-c", f"shell_environment_policy.set.ASKKEY_BROKER_SOCKET={json.dumps(socket_path)}",
                    "-c", 'shell_environment_policy.set.PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"',
                    "--output-schema", str(schema), "--output-last-message", str(output / "answer.json"),
                    "帮我检查隔离测试 NAS 有没有配置 SSH 密钥。这是模拟环境，只检查测试服务并根据运行结果回答；只读，不修改配置，不显示密码或私钥内容。",
                ]
                timed_out = False
                with (output / "events.jsonl").open("w") as events, (output / "stderr.log").open("w") as errors:
                    model_environment = environment.copy()
                    model_environment["ASKKEY_BROKER_SOCKET"] = socket_path
                    model = subprocess.Popen(
                        command, cwd=root, env=model_environment,
                        stdout=events, stderr=errors, start_new_session=True,
                    )
                    try:
                        model.wait(timeout=args.timeout)
                    except subprocess.TimeoutExpired:
                        timed_out = True
                        stop(model)
                broker_events = root / "events.jsonl"
                raw_events = broker_events.read_text() if broker_events.exists() else ""
                (output / "broker-events.jsonl").write_text(raw_events)
                answer_path = output / "answer.json"
                try:
                    answer = json.loads(answer_path.read_text())
                except (ValueError, OSError):
                    answer = {}
                broker_rows = [json.loads(line) for line in raw_events.splitlines()]
                model_rows = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
                target_output_seen = False
                output_operation_ids = set()
                for row in model_rows:
                    item = row.get("item", {})
                    command_text = item.get("command", "")
                    if (row.get("type") != "item.completed" or item.get("type") != "command_execution"
                            or item.get("exit_code") != 0):
                        continue
                    try:
                        arguments = shlex.split(command_text)
                        if len(arguments) == 3 and arguments[0] in {"/bin/zsh", "/bin/bash", "/bin/sh"} and arguments[1] in {"-lc", "-c"}:
                            arguments = shlex.split(arguments[2])
                        if (arguments[:2] != [helper, "run"] or "--wait-for-approval" not in arguments
                                or arguments[-2:] != ["--", str(inspection)]):
                            continue
                        operation_id = arguments[arguments.index("--operation-id") + 1]
                    except (ValueError, IndexError):
                        continue
                    for line in item.get("aggregated_output", "").splitlines():
                        try:
                            payload = json.loads(line)
                        except ValueError:
                            continue
                        if (isinstance(payload, dict) and payload.get("ssh_enabled") is True
                                and payload.get("authorized_key_count") == 2
                                and payload.get("password_authentication_enabled") is False):
                            target_output_seen = True
                            output_operation_ids.add(operation_id)
                counts = {}
                for row in broker_rows:
                    counts[row.get("event")] = counts.get(row.get("event"), 0) + 1
                operation_ids = {row["operation_id"] for row in broker_rows if row.get("operation_id")}
                lifecycle = [row.get("event") for row in broker_rows if row.get("event") in {
                    "pending", "approved", "consumed", "spawn", "completed",
                }]
                summary = {
                    "model": "gpt-6-astra", "model_exit_code": model.returncode,
                    "codex_version": subprocess.check_output([args.codex, "--version"], text=True).strip(),
                    "helper_sha256": hashlib.sha256(Path(helper).read_bytes()).hexdigest(),
                    "broker_fixture_sha256": hashlib.sha256(Path(broker_executable).read_bytes()).hexdigest(),
                    "timed_out": timed_out, "broker_event_counts": counts,
                    "single_operation": len(operation_ids) == 1 and output_operation_ids == operation_ids,
                    "approval_execution_order_valid": lifecycle == ["pending", "approved", "consumed", "spawn", "completed"],
                    "target_output_seen_in_waiting_cli": target_output_seen,
                    "answer_matches_target": (
                        answer.get("ssh_enabled") is True
                        and answer.get("authorized_key_count") == 2
                        and answer.get("password_authentication_enabled") is False
                        and isinstance(answer.get("summary"), str) and bool(answer["summary"].strip())
                    ),
                    "scope": "real helper/Broker/target; synthetic vault and authentication; no real NAS",
                }
                # Event assertions are deliberately independent of model claims.
                summary["passed"] = (
                    not timed_out and model.returncode == 0 and summary["answer_matches_target"] and target_output_seen
                    and counts.get("catalog", 0) >= 1 and counts.get("pending", 0) >= 1
                    and counts.get("approved", 0) == 1 and counts.get("spawn", 0) == 1
                    and counts.get("completed", 0) == 1
                    and counts.get("consumed", 0) == 1 and counts.get("text_run", 0) == 2
                    and counts.get("rejected", 0) == 0 and counts.get("approval_failed", 0) == 0
                    and summary["single_operation"] and summary["approval_execution_order_valid"]
                )
                (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
                print(json.dumps(summary, ensure_ascii=False))
                if not summary["passed"]:
                    raise SystemExit(1)
            finally:
                if model is not None:
                    stop(model)
                stop(broker)


if __name__ == "__main__":
    main()
