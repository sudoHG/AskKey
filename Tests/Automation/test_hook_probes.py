"""Offline probe safety tests; only synthetic config and owned processes."""
import importlib.util
from contextlib import contextmanager
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import textwrap
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    with patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
        spec.loader.exec_module(module)
    return module


native = load_script("probe-pretool-hook")
command = load_script("probe-command-hooks")
probe_io = sys.modules["probe_io"]


@contextmanager
def rpc_executable(body):
    """A synthetic peer that exits even if the old reader blocks on a half line."""
    with tempfile.TemporaryDirectory() as directory:
        executable = Path(directory) / "rpc-fixture"
        executable.write_text(
            "#!" + sys.executable + "\n"
            "import json, os, signal, sys, time\n"
            "signal.alarm(3)\n" + textwrap.dedent(body))
        executable.chmod(0o700)
        yield executable


@contextmanager
def rpc_process(body):
    with rpc_executable(body) as executable:
        process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            yield process
        finally:
            probe_io.stop_owned_process_group(process)


class HookProbeTests(unittest.TestCase):
    def test_fixture_environment_clears_unknown_askkey_variables_and_resolves_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            link = root / "linked"
            real = root / "real"
            real.mkdir()
            link.symlink_to(real, target_is_directory=True)
            with patch.dict(os.environ, {"ASKKEY_FUTURE_OVERRIDE": "ambient", "LC_ALL": "ambient"}):
                environment = command._safe_environment(
                    debug_state=link, missing_broker=link / "missing.sock")
                child = subprocess.run(
                    [sys.executable, "-c", "import json, os; print(json.dumps(dict(os.environ)))"],
                    env=environment, capture_output=True, text=True, check=True)
            observed = json.loads(child.stdout)
            self.assertNotIn("ASKKEY_FUTURE_OVERRIDE", observed)
            self.assertEqual(observed["ASKKEY_DEBUG_RUN_DIRECTORY"], str(real.resolve()))
            self.assertEqual(observed["ASKKEY_BROKER_SOCKET"], str(real.resolve() / "missing.sock"))
            self.assertEqual(observed["LC_ALL"], "C")

    def test_native_helper_relay_clears_ambient_askkey_variables(self):
        with rpc_executable("""
            for line in sys.stdin:
                request = json.loads(line)
                result = {key: value for key, value in os.environ.items() if key.startswith('ASKKEY_')}
                print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """) as executable:
            output = io.StringIO()
            socket = executable.parent / "missing.sock"
            with patch.dict(os.environ, {"ASKKEY_DEBUG_RUN_DIRECTORY": "ambient",
                                         "ASKKEY_FUTURE_OVERRIDE": "ambient"}), \
                    patch.object(sys, "stdin", io.StringIO('{"id":1,"method":"initialize"}\n')), \
                    patch.object(sys, "stdout", output):
                native.relay(str(executable), str(executable.parent / "events.jsonl"), str(socket))
            response = json.loads(output.getvalue())
            self.assertEqual(response["result"], {"ASKKEY_BROKER_SOCKET": str(socket.resolve())})

    def test_owned_group_permission_denial_requires_only_exited_members(self):
        pid = 43210
        own_zombie = f"{pid} {os.getpid()} {pid} Z\n"
        cases = [
            ("only_exited", 0, own_zombie, True),
            ("exited_descendant", 0, own_zombie + f"43211 1 {pid} Z\n", True),
            ("live_leader", 0, f"{pid} {os.getpid()} {pid} S\n", False),
            ("live_descendant", 0, own_zombie + f"43211 1 {pid} S\n", False),
            ("wrong_parent", 0, f"{pid} 1 {pid} Z\n", False),
            ("wrong_group", 0, f"{pid} {os.getpid()} 43211 Z\n", False),
            ("missing_leader", 0, f"43211 1 {pid} Z\n", False),
            ("empty", 0, "", False),
            ("malformed", 0, "not process metadata\n", False),
            ("failed_query", 1, own_zombie, False),
            ("timed_out_query", None, "", False),
        ]
        for name, code, metadata, accepted in cases:
            with self.subTest(name=name):
                process = SimpleNamespace(pid=pid, returncode=None, stdin=None,
                                          stdout=None, stderr=None, wait=Mock())
                result = SimpleNamespace(returncode=code, stdout=metadata)
                with patch.object(probe_io.os, "killpg", side_effect=PermissionError(1, "fixture")), \
                        patch.object(probe_io.subprocess, "run", return_value=result,
                                     side_effect=subprocess.TimeoutExpired("ps", 1) if code is None else None):
                    if accepted:
                        probe_io.stop_owned_process_group(process)
                        process.wait.assert_called_once_with(timeout=3)
                    else:
                        with self.assertRaises(PermissionError):
                            probe_io.stop_owned_process_group(process)
                        process.wait.assert_not_called()

    def test_owned_group_cleanup_never_signals_reaped_child(self):
        process = SimpleNamespace(pid=43210, returncode=0, stdin=None,
                                  stdout=None, stderr=None, wait=Mock())
        with patch.object(probe_io.os, "killpg") as kill_group, \
                patch.object(probe_io.subprocess, "run") as read_metadata:
            probe_io.stop_owned_process_group(process)
        kill_group.assert_not_called()
        read_metadata.assert_not_called()
        process.wait.assert_not_called()

    def test_command_rpc_partial_line_obeys_deadline(self):
        with rpc_process("""
            os.write(sys.stdout.fileno(), b'{"id":1')
            signal.pause()
        """) as process:
            self.assertTrue(select.select([process.stdout], [], [], 1)[0],
                            "fixture must write its partial frame before timing starts")
            self.assertIsNone(process.poll(), "fixture must still be holding the half line")
            started = time.monotonic()
            with self.assertRaises(command.ProbeFailure):
                command._read_rpc(process, 1, timeout=0.2)
            self.assertLess(time.monotonic() - started, 1)

    def test_command_rpc_notification_flood_does_not_extend_deadline(self):
        with rpc_process("""
            while True:
                print(json.dumps({"jsonrpc": "2.0", "method": "fixture/notice"}), flush=True)
                time.sleep(0.01)
        """) as process:
            started = time.monotonic()
            with self.assertRaises(command.ProbeFailure):
                command._read_rpc(process, 1, timeout=0.2)
            self.assertLess(time.monotonic() - started, 1)

    def test_command_rpc_multiple_frames_preserve_buffered_response(self):
        with rpc_process("""
            frames = [{"jsonrpc": "2.0", "method": "fixture/notice"},
                      {"id": 1, "result": {"first": True}},
                      {"id": 2, "result": {"second": True}}]
            os.write(sys.stdout.fileno(), ("\\n".join(json.dumps(row) for row in frames) + "\\n").encode())
            signal.pause()
        """) as process:
            self.assertTrue(select.select([process.stdout], [], [], 2)[0],
                            "fixture must write its frames before the RPC read deadline starts")
            self.assertEqual(command._read_rpc(process, 1, timeout=0.3),
                             {"id": 1, "result": {"first": True}})
            self.assertEqual(command._read_rpc(process, 2, timeout=0.3),
                             {"id": 2, "result": {"second": True}})

    def test_command_rpc_rejects_oversized_response(self):
        with rpc_process("""
            print(json.dumps({"id": 1, "result": "x" * (256 * 1024 + 1)}), flush=True)
            signal.pause()
        """) as process:
            self.assertTrue(select.select([process.stdout], [], [], 2)[0],
                            "fixture must begin its oversized frame before the RPC read deadline starts")
            with self.assertRaises(command.ProbeFailure):
                command._read_rpc(process, 1, timeout=0.3)

    def test_native_list_hooks_partial_line_obeys_deadline(self):
        with rpc_executable("""
            sys.stdin.readline()
            os.write(sys.stdout.fileno(), b'{"id":1')
            signal.pause()
        """) as executable:
            started = time.monotonic()
            with patch.object(native, "RPC_TIMEOUT_SECONDS", 0.2, create=True):
                with self.assertRaises(TimeoutError):
                    native.list_hooks(str(executable), executable.parent, [])
            self.assertLess(time.monotonic() - started, 1)

    def test_native_list_hooks_multiple_frames_keep_json_contract(self):
        with rpc_executable("""
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                result = {} if request["id"] == 1 else {"data": [{"hooks": [], "errors": [], "warnings": []}]}
                frames = [{"method": "fixture/notice"}, {"id": request["id"], "result": result}]
                os.write(sys.stdout.fileno(), ("\\n".join(json.dumps(row) for row in frames) + "\\n").encode())
        """) as executable:
            # This checks framing, not cold process startup performance.
            with patch.object(native, "RPC_TIMEOUT_SECONDS", 2, create=True):
                self.assertEqual(native.list_hooks(str(executable), executable.parent, []),
                                 {"hooks": [], "errors": [], "warnings": []})

    def test_native_list_hooks_rpc_error_omits_server_message(self):
        secret = "SYNTHETIC-RPC-ERROR-CONFIG-MUST-NOT-PERSIST"
        with rpc_executable("""
            request = json.loads(sys.stdin.readline())
            print(json.dumps({"id": request["id"], "error": {"code": -32603,
                  "message": "SYNTHETIC-RPC-ERROR-CONFIG-MUST-NOT-PERSIST",
                  "data": {"config": "SYNTHETIC-RPC-ERROR-CONFIG-MUST-NOT-PERSIST"}}}), flush=True)
            signal.pause()
        """) as executable:
            with self.assertRaises(RuntimeError) as failure:
                native.list_hooks(str(executable), executable.parent, [])
            self.assertNotIn(secret, str(failure.exception))

    def test_native_relay_partial_line_obeys_deadline(self):
        with rpc_executable("""
            sys.stdin.readline()
            os.write(sys.stdout.fileno(), b'{"id":1')
            signal.pause()
        """) as executable:
            started = time.monotonic()
            with patch.object(native, "RPC_TIMEOUT_SECONDS", 0.2, create=True), \
                    patch.object(sys, "stdin", io.StringIO('{"id":1,"method":"initialize"}\n')), \
                    patch.object(sys, "stdout", io.StringIO()):
                with self.assertRaises(TimeoutError):
                    native.relay(str(executable), str(executable.parent / "events.jsonl"),
                                 str(executable.parent / "missing.sock"))
            self.assertLess(time.monotonic() - started, 1)

    def test_native_relay_multiple_frames_keep_json_contract(self):
        with rpc_executable("""
            for line in sys.stdin:
                request = json.loads(line)
                if "id" not in request:
                    continue
                frames = [{"method": "fixture/notice"}, {"id": request["id"], "result": {"ok": True}}]
                os.write(sys.stdout.fileno(), ("\\n".join(json.dumps(row) for row in frames) + "\\n").encode())
        """) as executable:
            requests = '{"id":1,"method":"initialize"}\n{"id":2,"method":"ping"}\n'
            output = io.StringIO()
            # This checks framing, not cold process startup performance.
            with patch.object(native, "RPC_TIMEOUT_SECONDS", 2, create=True), \
                    patch.object(sys, "stdin", io.StringIO(requests)), \
                    patch.object(sys, "stdout", output):
                native.relay(str(executable), str(executable.parent / "events.jsonl"),
                             str(executable.parent / "missing.sock"))
            self.assertEqual([json.loads(line) for line in output.getvalue().splitlines()],
                             [{"id": 1, "result": {"ok": True}},
                              {"id": 2, "result": {"ok": True}}])

    def test_native_preflight_evidence_omits_unrelated_configuration(self):
        secret = "SYNTHETIC-UNRELATED-CONFIG-MUST-NOT-PERSIST"
        foreign = {"key": secret, "enabled": False, "isManaged": False,
                   "command": secret, "args": [secret], "path": secret}
        own = {"key": "fixture-own", "enabled": True, "isManaged": False,
               "server": "askkey", "tool": "credential_discovery_guard",
               "currentHash": "fixture-hash", "trustStatus": "trusted",
               "unexpectedField": secret}
        baseline = {"hooks": [foreign], "errors": [], "warnings": []}
        configured = {"hooks": [foreign, own], "errors": [], "warnings": [], "cwd": secret}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            with patch.object(sys, "argv", ["probe", "--output", str(output), "--preflight-only"]), \
                    patch.object(native, "list_hooks", side_effect=[baseline, configured, configured]):
                native.main()
            for filename in ["configured.json", "verified.json"]:
                raw = (output / filename).read_text()
                self.assertNotIn(secret, raw)
                facts = json.loads(raw)
                self.assertEqual(facts["hook_count"], 2)
                self.assertEqual(facts["enabled_count"], 1)
                self.assertEqual(facts["askkey_hooks"], [{"enabled": True, "managed": False,
                                                       "trust_status": "trusted"}])

    def test_capture_timeout_reaps_descendant_holding_output_pipe(self):
        # The descendant self-expires, so even the old broken implementation
        # cannot hang this regression or leave a persistent fixture behind.
        fixture = """
import os, signal, sys, time
child = os.fork()
if child == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.alarm(5)
    print('descendant-ready', os.getpid(), flush=True)
    while True:
        signal.pause()
while True:
    signal.pause()
"""
        with tempfile.TemporaryDirectory() as directory:
            started = time.monotonic()
            code, stdout, stderr, timed_out = command._capture(
                [sys.executable, "-c", fixture], cwd=Path(directory),
                environment={"PATH": "/usr/bin:/bin"}, timeout=0.4)
            self.assertTrue(timed_out)
            self.assertNotEqual(code, 0)
            self.assertIn(b"descendant-ready", stdout)
            self.assertLess(time.monotonic() - started, 3)
            child_pid = int(stdout.split(b"descendant-ready ", 1)[1].splitlines()[0])
            # Timing alone would also pass if only the leader died and the
            # read pipe was closed. Check the actual descendant before its
            # self-expiry; zombies have exited and cannot retain the pipe.
            state = subprocess.run(["/bin/ps", "-p", str(child_pid), "-o", "stat="],
                                   capture_output=True, text=True, timeout=1)
            self.assertTrue(state.returncode != 0 or state.stdout.strip().startswith("Z"),
                            "owned descendant still running after timeout cleanup")

    def test_capture_normal_completion_preserves_output(self):
        code, stdout, stderr, timed_out = command._capture(
            [sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)"],
            cwd=ROOT, environment={"PATH": "/usr/bin:/bin"}, timeout=3)
        self.assertEqual((code, stdout, stderr, timed_out), (0, b"out\n", b"err\n", False))


if __name__ == "__main__":
    unittest.main()
