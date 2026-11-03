#!/usr/bin/env python3
"""Recover notarization requests without receiving delivered credential values."""

import argparse
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}")
TRANSIENT = re.compile(
    r"NSURLErrorDomain[^\r\n]*?(?<!\d)-(?:1001|1003|1004|1005|1006|1009)(?!\d)"
)
FAILURES = {
    "approval": "Ask Key request did not start; check approval denial, timeout, credential delivery, or helper failure",
    "deadline": "Notarization reached its 30-minute deadline",
    "adopted-incomplete": "Adopted submission is still In Progress at the deadline; its upload may be incomplete; check notarytool log before resubmitting",
    "request": "Notarytool failed; check authentication and credential delivery",
    "submission": "Notarization submission failed without a usable ID",
    "history": "Submission history is unavailable or invalid; do not resubmit automatically",
    "ambiguous": "Ambiguous matching submission history; inspect every reported ID before proceeding",
    "attempts": "Submission retry limit reached without a usable ID",
    "status": "Notarization returned an invalid or unexpected status",
    "rejected": "Notarization was rejected",
}
REQUEST_STARTED = b"ASKKEY_NOTARY_REQUEST_STARTED\n"
TARGET_SHELL = (
    'set +x; set -eu; [[ -f "$PRIVATE_KEY_FILE" && -r "$PRIVATE_KEY_FILE" ]] || exit 1; '
    'printf "%s\\n" ASKKEY_NOTARY_REQUEST_STARTED; '
    'exec xcrun notarytool "$@" --key "$PRIVATE_KEY_FILE" --key-id "$KEY_ID" '
    '--issuer "$ISSUER_ID" --output-format json'
)


class Failure(Exception):
    pass


def emit(record):
    print(json.dumps(record), flush=True)


class Notarizer:
    def __init__(self, artifact, auth=(), *, credential=None, helper=None, version=None,
                 clock=time.monotonic, sleep=time.sleep,
                 now=lambda: datetime.now(timezone.utc), run=subprocess.run, report=emit):
        self.artifact = artifact
        self.auth = list(auth)
        self.credential, self.helper, self.version = credential, helper, version
        self.clock, self.sleep, self.now = clock, sleep, now
        self.run, self.report = run, report
        self.deadline = clock() + 30 * 60
        self.delay = 5
        self.ids = []
        self.upload_started = False
        self.adopted = False
        self.adopted_in_progress = False

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
        command = ["xcrun", "notarytool", action, *arguments, *self.auth, "--output-format", "json"]
        if self.credential:
            # Approval waiting and execution both consume the artifact's budget.
            command = [
                self.helper, "run", "--wait-for-approval", "--credential", self.credential,
                "--operation-id", str(uuid.uuid4()), "--caller-name", "AskKey release",
                "--caller-purpose", f"Notarize AskKey {self.version}", "--",
                "/bin/bash", "-c", TARGET_SHELL, "bash", action, *arguments,
            ]
        elif action == "submit":
            self.mark_upload_started()
        try:
            result = self.run(
                command,
                stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
            )
        except subprocess.TimeoutExpired as error:
            timed_out = True
            result = subprocess.CompletedProcess([], 1, error.output or b"", error.stderr or b"")
        except OSError:
            raise Failure("request") from None
        # Raw diagnostics stay in memory, including on decoding or parse failure.
        output = result.stdout
        if self.credential:
            if not output.startswith(REQUEST_STARTED):
                if timed_out and self.clock() >= self.deadline:
                    raise Failure("deadline")
                raise Failure("approval")
            output = output[len(REQUEST_STARTED):]
            if action == "submit":
                self.mark_upload_started()
        stdout = output.decode("utf-8", errors="replace")
        stderr = result.stderr.decode("utf-8", errors="replace")
        transient = timed_out or bool(TRANSIENT.search(stdout + "\n" + stderr))
        try:
            data = json.loads(stdout)
        except ValueError:
            data = None
        return data, transient, result.returncode == 0

    def mark_upload_started(self):
        if not self.upload_started:
            self.upload_started = True
            self.report({"event": "upload-started"})

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
        empty_snapshots = 0
        while empty_snapshots < 3:
            self.pause()
            data, transient, success = self.request("history")
            if data is None and transient and not success:
                continue
            if not isinstance(data, dict) or not isinstance(data.get("history"), list):
                raise Failure("history")
            matches = []
            skewed = False
            try:
                for entry in data["history"]:
                    if entry["name"] != Path(self.artifact).name:
                        continue
                    created = datetime.fromisoformat(entry["createdDate"].replace("Z", "+00:00"))
                    if created.tzinfo is None:
                        raise ValueError()
                    if created < started - timedelta(minutes=3):
                        continue
                    if not self.remember(entry["id"]):
                        raise ValueError()
                    if entry["id"].lower() not in matches:
                        matches.append(entry["id"].lower())
                    if created < started:
                        skewed = True
            except (KeyError, TypeError, ValueError, AttributeError):
                raise Failure("history") from None
            if not success and not transient:
                raise Failure("history")
            if skewed or len(matches) > 1:
                raise Failure("ambiguous")
            if matches:
                return matches[0]
            if not success:
                continue
            empty_snapshots += 1
        return None

    def submit(self):
        started = self.now().replace(microsecond=0)
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
                self.adopted = True
                return recovered
        raise Failure("attempts")

    def notarize(self):
        submission_id = self.submit()
        try:
            self.poll(submission_id)
        except Failure as error:
            if str(error) == "deadline" and self.adopted_in_progress:
                raise Failure("adopted-incomplete") from None
            raise

    def poll(self, submission_id):
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
                    self.adopted_in_progress = self.adopted
                    self.pause()
                    continue
            if not transient:
                raise Failure("status" if success else "request")
            self.pause()


def summarize(path, completed=False, *, ids_only=False):
    ids = []
    started = accepted = upload_started = False
    reason = "approval"
    try:
        with open(path, encoding="utf-8") as response:
            for line in response:
                result = json.loads(line)
                event = result["event"]
                if event == "started":
                    started = True
                    reason = "request"
                elif event == "upload-started":
                    upload_started = True
                elif event == "submission" and UUID.fullmatch(result["id"]):
                    if result["id"] not in ids:
                        ids.append(result["id"])
                elif event == "accepted" and ids == [result["id"]]:
                    accepted = True
                elif event == "failed" and result["reason"] in FAILURES:
                    accepted = False
                    reason = result["reason"]
                else:
                    raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        accepted = False
        reason = "status"
    for submission_id in ids:
        print(f"Notarization submission: {submission_id}", flush=True)
    if ids_only:
        return 0
    if completed and started and accepted:
        return 0
    message = FAILURES[reason]
    if upload_started and reason == "approval":
        message = "Ask Key approval or credential delivery failed after an upload started"
    print("Error: " + message, file=sys.stderr)
    if ids:
        for submission_id in ids:
            print(f"Inspect with: xcrun notarytool log {submission_id} <authentication-options>", file=sys.stderr)
    elif upload_started:
        print("No submission ID available; inspect notarytool history before submitting again.", file=sys.stderr)
    return 1


def main():
    if len(sys.argv) > 2 and sys.argv[1] in ("--summarize", "--report-ids"):
        return summarize(sys.argv[2], completed=sys.argv[3:] == ["true"],
                         ids_only=sys.argv[1] == "--report-ids")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact")
    auth = parser.add_mutually_exclusive_group(required=True)
    auth.add_argument("--credential")
    auth.add_argument("--keychain-profile")
    parser.add_argument("--helper")
    parser.add_argument("--version")
    args = parser.parse_args()
    if args.credential and (not args.helper or not args.version):
        parser.error("credential mode requires --helper and --version")
    emit({"event": "started"})
    try:
        Notarizer(args.artifact,
                  ["--keychain-profile", args.keychain_profile] if args.keychain_profile else (),
                  credential=args.credential, helper=args.helper, version=args.version).notarize()
        return 0
    except Failure as error:
        emit({"event": "failed", "reason": str(error)})
    except (OSError, ValueError, IndexError):
        emit({"event": "failed", "reason": "request"})
    return 1


if __name__ == "__main__":
    sys.exit(main())
