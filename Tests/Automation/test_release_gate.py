"""Exercise release CI provenance and failures without GitHub or network access."""

import copy
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_gate", ROOT / "scripts/release-gate.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)

HEAD = "a" * 40
REPOSITORY = "synthetic/askkey"
RUN_URL = "https://github.com/synthetic/askkey/actions/runs/42"


class ReleaseGateTests(unittest.TestCase):
    def setUp(self):
        self.dirty = ""
        self.on_main = True
        self.tagged = HEAD
        self.calls = []
        self.runs = [{"id": 42, "name": "CI", "head_sha": HEAD, "event": "push",
                      "head_branch": "main", "created_at": "2026-10-04T00:00:00Z",
                      "run_attempt": 2, "status": "completed", "conclusion": "success",
                      "html_url": RUN_URL}]
        self.jobs = [{"name": name, "status": "completed", "conclusion": "success"}
                     for name in gate.REQUIRED_JOBS]
        self.run_pages = None
        self.job_pages = None
        self.run_response = None
        self.repo_response = json.dumps({"nameWithOwner": REPOSITORY})

    def command(self, arguments, failure):
        arguments = tuple(arguments)
        self.calls.append(arguments)
        if arguments == ("git", "status", "--porcelain"):
            return self.dirty
        if arguments == ("git", "fetch", "origin", "main"):
            return ""
        if arguments == ("git", "rev-parse", "HEAD"):
            return HEAD
        if arguments == ("git", "merge-base", "--is-ancestor", HEAD, "origin/main"):
            if not self.on_main:
                raise gate.GateError(failure)
            return ""
        if arguments == ("gh", "repo", "view", "--json", "nameWithOwner"):
            return self.repo_response
        if arguments[:3] == ("gh", "api", f"repos/{REPOSITORY}/actions/workflows/ci.yml/runs"):
            return (self.run_response if self.run_response is not None
                    else json.dumps(self.run_pages or [{"workflow_runs": self.runs}]))
        if arguments[:3] == ("gh", "api", f"repos/{REPOSITORY}/actions/runs/42/attempts/2/jobs"):
            return json.dumps(self.job_pages or [{"jobs": self.jobs}])
        if arguments == ("bash", "scripts/product-version.sh"):
            return "0.1.0"
        if arguments == ("git", "rev-parse", "v0.1.0^{commit}"):
            if self.tagged is None:
                raise gate.GateError(failure)
            return self.tagged
        self.fail(f"Unexpected command: {arguments}")

    def check(self, require_tag=False):
        with mock.patch.object(gate, "run_command", side_effect=self.command):
            return gate.check_release(require_tag)

    def test_passes_for_clean_main_with_successful_ci(self):
        self.assertEqual(self.check(), f"Release gate passed: {HEAD[:7]}, CI run {RUN_URL}")
        fetch = self.calls.index(("git", "fetch", "origin", "main"))
        ancestor = self.calls.index(("git", "merge-base", "--is-ancestor", HEAD, "origin/main"))
        self.assertLess(fetch, ancestor)

    def test_dirty_tracked_and_untracked_files_stop_before_fetch(self):
        for status in (" M tracked.swift", "?? untracked.txt"):
            with self.subTest(status=status):
                self.calls.clear()
                self.dirty = status
                with self.assertRaisesRegex(gate.GateError, "Checkout is not clean"):
                    self.check()
                self.assertEqual(self.calls, [("git", "status", "--porcelain")])

    def test_commit_not_reachable_from_main_is_rejected(self):
        self.on_main = False
        with self.assertRaisesRegex(gate.GateError, "not reachable from origin/main"):
            self.check()
        self.assertFalse(any(call[0] == "gh" for call in self.calls))

    def test_no_ci_run_is_rejected(self):
        self.runs = []
        with self.assertRaisesRegex(gate.GateError, "No push-to-main CI run"):
            self.check()

    def test_failed_run_is_rejected(self):
        self.runs[0]["conclusion"] = "failure"
        with self.assertRaisesRegex(gate.GateError, "CI run did not succeed"):
            self.check()

    def test_unfinished_run_is_rejected_even_with_a_success_conclusion(self):
        for status in ("queued", "in_progress", "waiting"):
            with self.subTest(status=status):
                self.runs[0]["status"] = status
                with self.assertRaisesRegex(gate.GateError, "CI run is not completed"):
                    self.check()

    def test_each_failed_required_job_is_rejected(self):
        for index, name in enumerate(gate.REQUIRED_JOBS):
            with self.subTest(job=name):
                self.jobs[index]["conclusion"] = "failure"
                with self.assertRaisesRegex(gate.GateError, f"CI job {name} did not succeed"):
                    self.check()
                self.jobs[index]["conclusion"] = "success"

    def test_each_missing_required_job_is_rejected(self):
        original = self.jobs
        for name in gate.REQUIRED_JOBS:
            with self.subTest(job=name):
                self.jobs = [job for job in original if job["name"] != name]
                with self.assertRaisesRegex(gate.GateError, f"CI job {name} is missing"):
                    self.check()

    def test_latest_failed_run_on_another_page_cannot_use_older_success(self):
        older = dict(self.runs[0], id=41, created_at="2026-10-03T00:00:00Z")
        self.runs[0]["conclusion"] = "failure"
        self.run_pages = [{"workflow_runs": [older]}, {"workflow_runs": self.runs}]
        with self.assertRaisesRegex(gate.GateError, "CI run did not succeed"):
            self.check()

    def test_wrong_workflow_event_branch_or_commit_is_rejected(self):
        original = copy.deepcopy(self.runs[0])
        for key, value in (("name", "Other"), ("event", "pull_request"),
                           ("head_branch", "task/synthetic"), ("head_sha", "b" * 40)):
            with self.subTest(key=key):
                self.runs = [dict(original, **{key: value})]
                with self.assertRaisesRegex(gate.GateError, "No push-to-main CI run"):
                    self.check()

    def test_only_the_latest_attempt_jobs_are_requested(self):
        self.check()
        requests = [call for call in self.calls if call[:2] == ("gh", "api")]
        self.assertIn("head_sha=" + HEAD, requests[0])
        self.assertIn("event=push", requests[0])
        self.assertIn("branch=main", requests[0])
        self.assertEqual(requests[1][2], f"repos/{REPOSITORY}/actions/runs/42/attempts/2/jobs")

    def test_required_jobs_on_different_pages_are_accepted(self):
        self.job_pages = [{"jobs": self.jobs[:1]}, {"jobs": self.jobs[1:]}]
        self.assertIn("Release gate passed", self.check())

    def test_unfinished_required_job_is_rejected(self):
        self.jobs[0]["status"] = "in_progress"
        with self.assertRaisesRegex(gate.GateError, "CI job build-and-test did not succeed"):
            self.check()

    def test_duplicate_failed_required_job_cannot_hide_behind_success(self):
        self.jobs.append(dict(self.jobs[0], conclusion="failure"))
        with self.assertRaisesRegex(gate.GateError, "CI job build-and-test did not succeed"):
            self.check()

    def test_missing_version_tag_is_rejected(self):
        self.tagged = None
        with self.assertRaisesRegex(gate.GateError, "Tag v0.1.0 is missing"):
            self.check(require_tag=True)

    def test_version_tag_on_another_commit_is_rejected(self):
        self.tagged = "b" * 40
        with self.assertRaisesRegex(gate.GateError, "Tag v0.1.0 does not point to HEAD"):
            self.check(require_tag=True)

    def test_matching_version_tag_is_accepted(self):
        self.assertIn("Release gate passed", self.check(require_tag=True))
        self.assertEqual(self.calls[-1], ("git", "rev-parse", "v0.1.0^{commit}"))

    def test_local_gate_does_not_check_a_tag(self):
        self.tagged = None
        self.check()
        self.assertFalse(any(call[0] == "bash" for call in self.calls))

    def test_invalid_api_responses_fail_closed(self):
        for response in ("not JSON", "{}", "[]", '[{"workflow_runs":null}]'):
            with self.subTest(response=response):
                self.run_response = response
                with self.assertRaisesRegex(gate.GateError, "Unable to read CI workflow runs"):
                    self.check()

    def test_missing_latest_attempt_metadata_is_rejected(self):
        del self.runs[0]["run_attempt"]
        with self.assertRaisesRegex(gate.GateError, "metadata is incomplete"):
            self.check()

    def test_main_emits_one_clear_failure_line(self):
        self.dirty = "?? untracked.txt"
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.object(gate, "run_command", side_effect=self.command), \
                redirect_stdout(output), redirect_stderr(error):
            self.assertEqual(gate.main([]), 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(error.getvalue(),
                         "Release gate failed: Checkout is not clean (tracked or untracked changes).\n")

    def test_command_timeout_is_bounded_and_reported(self):
        with mock.patch.object(gate.subprocess, "check_output",
                               side_effect=subprocess.TimeoutExpired("git", 60)) as command:
            with self.assertRaisesRegex(gate.GateError, "Unable to fetch.*Command timed out"):
                gate.run_command(["git", "fetch", "origin", "main"], "Unable to fetch.")
        self.assertEqual(command.call_args.kwargs["timeout"], gate.COMMAND_TIMEOUT)

    def test_command_failure_and_missing_tool_fail_closed(self):
        for error in (subprocess.CalledProcessError(1, "gh"), FileNotFoundError("gh")):
            with self.subTest(error=type(error).__name__), \
                    mock.patch.object(gate.subprocess, "check_output", side_effect=error):
                with self.assertRaisesRegex(gate.GateError, "Unable to read CI jobs"):
                    gate.run_command(["gh", "api", "synthetic"], "Unable to read CI jobs.")


if __name__ == "__main__":
    unittest.main()
