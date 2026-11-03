#!/usr/bin/env python3
"""Run one artifact's notarization inside its delivered-credential process."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
TRANSIENT = re.compile(
    r"NSURLErrorDomain[^\r\n]*?(?<!\d)-(?:1001|1003|1004|1005|1006|1009)(?!\d)"
)
FAILURES = {
    "credentials": "Delivered credentials could not be read before expiry",
    "deadline": "Notarization reached its 30-minute deadline",
    "request": "Notarytool failed; check authentication and inherited key-pipe support",
    "submission": "Notarization submission failed without a usable ID",
    "history": "Submission history is unavailable or invalid; do not resubmit automatically",
    "ambiguous": "Multiple matching submissions found; inspect every ID before proceeding",
    "attempts": "Submission retry limit reached without a usable ID",
    "status": "Notarization returned an invalid or unexpected status",
    "rejected": "Notarization was rejected",
}


class Failure(Exception):
    pass


def emit(record):
    print(json.dumps(record), flush=True)


class Notarizer:
    def __init__(self, artifact, auth, *, clock=time.monotonic, sleep=time.sleep,
                 now=lambda: datetime.now(timezone.utc), run=subprocess.run, report=emit):
        self.artifact = artifact
        self.auth = list(auth)
        self.clock, self.sleep, self.now = clock, sleep, now
        self.run, self.report = run, report
        self.deadline = clock() + 30 * 60
        self.delay = 5
        self.ids = []
        self.key = None
        if "--key" in self.auth:
            try:
                self.key = Path(self.auth[self.auth.index("--key") + 1]).read_bytes()
                if not self.key:
                    raise ValueError()
            except (OSError, ValueError, IndexError):
                raise Failure("credentials") from None

    def remaining(self):
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise Failure("deadline")
        return remaining

    def pause(self):
        self.sleep(min(self.delay, self.remaining()))
        self.delay = min(self.delay * 2, 60)
        self.remaining()

    def request(self, action, *arguments):
        timeout = min(300 if action == "submit" else 120, self.remaining())
        timed_out = False
        auth = self.auth.copy()
        reader = None
        writer = None
        if self.key is not None:
            reader, write_fd = os.pipe()
            auth[auth.index("--key") + 1] = f"/dev/fd/{reader}"

            def feed_key():
                try:
                    with os.fdopen(write_fd, "wb") as pipe:
                        pipe.write(self.key)
                except OSError:
                    pass  # A failed or timed-out child may close its reader early.

            writer = threading.Thread(target=feed_key, daemon=True)
            writer.start()
        try:
            result = self.run(
                ["xcrun", "notarytool", action, *arguments, *auth, "--output-format", "json"],
                stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                pass_fds=() if reader is None else (reader,),
            )
        except subprocess.TimeoutExpired as error:
            timed_out = True
            result = subprocess.CompletedProcess([], 1, error.output or b"", error.stderr or b"")
        except OSError:
            raise Failure("request") from None
        finally:
            if reader is not None:
                os.close(reader)
                writer.join()
        # Raw diagnostics stay in memory, including on decoding or parse failure.
        stdout = result.stdout.decode("utf-8", errors="replace")
        stderr = result.stderr.decode("utf-8", errors="replace")
        transient = timed_out or bool(TRANSIENT.search(stdout + "\n" + stderr))
        try:
            data = json.loads(stdout)
        except ValueError:
            data = None
        return data, transient, result.returncode == 0

    def remember(self, submission_id):
        if not isinstance(submission_id, str) or not UUID.fullmatch(submission_id):
            return False
        submission_id = submission_id.lower()
        if submission_id not in self.ids:
            self.ids.append(submission_id)
            self.report({"event": "submission", "id": submission_id})
        return True

    def reconcile(self, started):
        # Require repeated successful empty snapshots before another upload, and
        # include all attempts in the time window to catch a delayed prior upload.
        for _ in range(3):
            self.pause()
            data, _, success = self.request("history")
            if not success or not isinstance(data, dict) or not isinstance(data.get("history"), list):
                raise Failure("history")
            matches = []
            try:
                for entry in data["history"]:
                    if entry["name"] != Path(self.artifact).name:
                        continue
                    created = datetime.fromisoformat(entry["createdDate"].replace("Z", "+00:00"))
                    if created.tzinfo is None:
                        raise ValueError()
                    if created < started:
                        continue
                    if not self.remember(entry["id"]):
                        raise ValueError()
                    if entry["id"].lower() not in matches:
                        matches.append(entry["id"].lower())
            except (KeyError, TypeError, ValueError, AttributeError):
                raise Failure("history") from None
            if len(matches) > 1:
                raise Failure("ambiguous")
            if matches:
                return matches[0]
        return None

    def submit(self):
        started = self.now()
        for _ in range(3):
            data, transient, success = self.request("submit", self.artifact, "--no-wait")
            if isinstance(data, dict) and self.remember(data.get("id")):
                if success or transient:
                    return data["id"].lower()
                raise Failure("request")
            if not transient:
                raise Failure("submission" if success else "request")
            recovered = self.reconcile(started)
            if recovered:
                return recovered
        raise Failure("attempts")

    def notarize(self):
        submission_id = self.submit()
        while True:
            data, transient, success = self.request("info", submission_id)
            if isinstance(data, dict) and isinstance(data.get("id"), str):
                if data["id"].lower() != submission_id:
                    raise Failure("status")
                status = data.get("status")
                if status in ("Invalid", "Rejected"):
                    raise Failure("rejected")
                if success and status == "Accepted":
                    self.report({"event": "accepted", "id": submission_id})
                    return
                if success and status == "In Progress":
                    self.pause()
                    continue
            if not transient:
                raise Failure("status" if success else "request")
            self.pause()


def main():
    emit({"event": "started"})
    try:
        Notarizer(sys.argv[1], sys.argv[2:]).notarize()
        return 0
    except Failure as error:
        emit({"event": "failed", "reason": str(error)})
    except (OSError, ValueError, IndexError):
        emit({"event": "failed", "reason": "request"})
    return 1


if __name__ == "__main__":
    sys.exit(main())
