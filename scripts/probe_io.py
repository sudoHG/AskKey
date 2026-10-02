"""Bounded JSON-RPC response reads and cleanup for the opt-in local probes."""

from __future__ import annotations

import errno
import json
import os
import select
import signal
import subprocess
import time
from typing import Any


MAX_RPC_FRAME_BYTES = 256 * 1024


class RPCReadError(RuntimeError):
    """A fixed local error label; never contains bytes supplied by a peer."""


class _ResponseReader:
    def __init__(self, stream: Any, maximum_bytes: int):
        self.fd = stream.fileno()
        self.maximum_bytes = maximum_bytes
        self.pending = bytearray()
        os.set_blocking(self.fd, False)

    def response(self, expected_id: Any, timeout: float) -> dict[str, Any]:
        # One deadline covers all notifications and partial chunks for this
        # response. Keep unread complete frames for the next request, too.
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("rpc_response_timeout")
            newline = self.pending.find(b"\n")
            if newline >= 0:
                if newline > self.maximum_bytes:
                    raise RPCReadError("rpc_response_too_large")
                line = bytes(self.pending[:newline])
                del self.pending[:newline + 1]
                try:
                    value = json.loads(line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue
                if isinstance(value, dict) and value.get("id") == expected_id:
                    return value
                continue
            if len(self.pending) > self.maximum_bytes:
                raise RPCReadError("rpc_response_too_large")
            try:
                if not select.select([self.fd], [], [], remaining)[0]:
                    raise TimeoutError("rpc_response_timeout")
                chunk = os.read(self.fd, min(8192, self.maximum_bytes + 1 - len(self.pending)))
            except (BlockingIOError, InterruptedError):
                continue
            if not chunk:
                raise RPCReadError("rpc_response_closed")
            self.pending.extend(chunk)


def read_rpc_response(process: subprocess.Popen, expected_id: Any, timeout: float,
                      maximum_bytes: int = MAX_RPC_FRAME_BYTES) -> dict[str, Any]:
    if process.stdout is None:
        raise RPCReadError("rpc_response_unavailable")
    reader = getattr(process, "_askkey_probe_response_reader", None)
    if reader is None:
        reader = _ResponseReader(process.stdout, maximum_bytes)
        process._askkey_probe_response_reader = reader
    return reader.response(expected_id, timeout)


def _close_pipes(process: subprocess.Popen) -> None:
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass


def _owned_group_has_only_exited_members(process: subprocess.Popen) -> bool:
    """Verify zombie-only membership without reaping or inspecting arguments."""
    if process.returncode is not None:
        return False
    try:
        result = subprocess.run(
            ["/bin/ps", "-g", str(process.pid), "-o", "pid=,ppid=,pgid=,stat="],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=1, check=False,
            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    if result.returncode != 0:
        return False
    own_leader_exited = False
    for row in result.stdout.splitlines():
        fields = row.split()
        if len(fields) != 4:
            return False
        try:
            pid, parent, group = (int(value) for value in fields[:3])
        except ValueError:
            return False
        if group != process.pid or not fields[3].startswith("Z"):
            return False
        if pid == process.pid:
            if parent != os.getpid():
                return False
            own_leader_exited = True
    # Missing/empty metadata is not evidence that our child has exited.
    return own_leader_exited


def _signal_owned_group(process: subprocess.Popen, signum: int) -> bool:
    try:
        os.killpg(process.pid, signum)
        return True
    except ProcessLookupError:
        return False
    except PermissionError as error:
        # macOS can return EPERM for a group containing only zombies. Accept
        # that only when both the retained child and every member are proven
        # exited; never fall back to signalling PIDs from the metadata.
        if error.errno != errno.EPERM or not _owned_group_has_only_exited_members(process):
            raise
        return False


def stop_owned_process_group(process: subprocess.Popen, *, close_pipes: bool = True) -> None:
    """Only for a start_new_session child whose group this caller owns."""
    try:
        if process.returncode is not None:
            return
        # Do not reap the leader before the last group signal: its retained
        # PID prevents targeting a reused process-group ID.
        if _signal_owned_group(process, signal.SIGTERM):
            time.sleep(0.2)
            _signal_owned_group(process, signal.SIGKILL)
        process.wait(timeout=3)
    finally:
        if close_pipes:
            _close_pipes(process)


def stop_owned_child(process: subprocess.Popen) -> None:
    """A relay helper shares its parent's group; never signal that group here."""
    try:
        if process.returncode is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
    finally:
        _close_pipes(process)
