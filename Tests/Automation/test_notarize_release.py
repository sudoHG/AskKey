"""Exercise deadlines, reconciliation and fresh helper requests without credentials."""

from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("notarize_release", ROOT / "scripts/notarize-release.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
ID = "12345678-1234-1234-1234-123456789abc"
OTHER_ID = "87654321-4321-4321-4321-cba987654321"
KEY = b"synthetic-private-key-bytes"


class NotarizeReleaseTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="notary-runner-test-")
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.elapsed = 0
        self.sleeps = []
        self.calls = []
        self.events = []
        self.target_started = True
        self.response = self.success
        self.start = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.runner = self.make_runner()

    def make_runner(self, credential=False):
        return MODULE.Notarizer(
            "AskKey.zip", () if credential else ["--keychain-profile", "synthetic-profile"],
            credential="synthetic-credential" if credential else None,
            helper="synthetic-askkey", version="1.2.3",
            clock=lambda: self.elapsed, sleep=self.sleep,
            now=lambda: self.start + timedelta(seconds=self.elapsed),
            run=self.tool, report=self.events.append,
        )

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.elapsed += seconds

    @staticmethod
    def result(data=None, *, error="", code=0):
        return subprocess.CompletedProcess([], code, json.dumps(data).encode(),
                                           (error + " synthetic-key-id synthetic-private-key-bytes").encode())

    def success(self, action, arguments, options):
        if action == "submit":
            return self.result({"id": ID})
        return self.result({"id": ID, "status": "Accepted"})

    def tool(self, arguments, **options):
        self.calls.append((arguments, options, self.elapsed))
        self.assertLess(self.elapsed, 1800)
        self.assertGreater(options["timeout"], 0)
        self.assertLessEqual(options["timeout"], 1800 - self.elapsed)
        self.assertNotIn("pass_fds", options)
        if arguments[0] != "synthetic-askkey":
            return self.response(arguments[2], arguments, options)
        self.assertEqual(options["timeout"], min(300 if arguments[16] == "submit" else 120,
                                                1800 - self.elapsed))
        self.assertEqual(arguments[1:5], ["run", "--wait-for-approval", "--credential", "synthetic-credential"])
        self.assertEqual(arguments[12:14], ["/bin/bash", "-c"])
        for name in ("PRIVATE_KEY_FILE", "KEY_ID", "ISSUER_ID"):
            self.assertIn(f'"${name}"', arguments[14])
        self.assertLess(len(arguments[14].encode()), 512)
        self.assertNotIn("synthetic-key-id", " ".join(arguments))
        marker = MODULE.REQUEST_STARTED if self.target_started else b""
        try:
            result = self.response(arguments[16], arguments, options)
        except subprocess.TimeoutExpired as error:
            error.output = marker + (error.output or b"")
            raise
        result.stdout = marker + result.stdout
        return result

    def actions(self):
        return [arguments[16] if arguments[0] == "synthetic-askkey" else arguments[2]
                for arguments, _, _ in self.calls]

    def assert_failure(self, reason):
        with self.assertRaisesRegex(MODULE.Failure, f"^{reason}$"):
            self.runner.notarize()
        self.assertNotIn("synthetic", json.dumps(self.events))

    def history_entry(self, submission_id=ID, *, name="AskKey.zip", seconds=1):
        return {"id": submission_id, "name": name,
                "createdDate": (self.start + timedelta(seconds=seconds)).isoformat()}

    def test_in_progress_uses_fresh_helper_requests_after_five_minutes(self):
        self.runner = self.make_runner(credential=True)
        def response(action, arguments, options):
            if action == "info" and self.elapsed < 350:
                return self.result({"id": ID, "status": "In Progress"})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertGreater(self.elapsed, 300)
        self.assertEqual(self.actions().count("submit"), 1)
        self.assertEqual(self.sleeps[:5], [5, 10, 20, 40, 60])
        self.assertLessEqual(max(self.sleeps), 60)
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})
        operations = [arguments[6] for arguments, _, _ in self.calls]
        self.assertEqual(len(operations), len(set(operations)))

    def test_fast_transient_errors_use_time_budget_not_four_attempts(self):
        for code in ("-1001", "-1003", "-1004", "-1005", "-1006", "-1009"):
            with self.subTest(code=code):
                self.elapsed = 0
                self.calls.clear()
                self.sleeps.clear()
                self.runner.delay = 5
                self.response = lambda action, args, opts: (
                    self.result({"id": ID}) if action == "submit" else
                    self.result(error=f"NSURLErrorDomain Code={code}", code=1))
                self.assert_failure("deadline")
                self.assertEqual(self.elapsed, 1800)
                self.assertGreater(self.actions().count("info"), 20)
                self.assertEqual(self.actions().count("submit"), 1)
                self.assertLessEqual(max(self.sleeps), 60)

    def test_slow_requests_and_backoff_share_one_deadline(self):
        def response(action, arguments, options):
            self.elapsed += options["timeout"]
            if action == "submit":
                return self.result({"id": ID})
            raise subprocess.TimeoutExpired(arguments, options["timeout"], output=KEY, stderr=KEY)

        self.response = response
        self.assert_failure("deadline")
        self.assertEqual(self.elapsed, 1800)
        self.assertEqual(self.actions().count("submit"), 1)

    def test_transient_errors_recover_through_fresh_helper_requests(self):
        self.runner = self.make_runner(credential=True)
        def response(action, arguments, options):
            if action == "info" and self.actions().count("info") <= 10:
                return subprocess.CompletedProcess(arguments, 1, b"\xffsynthetic-private-key-bytes",
                                                   b"NSURLErrorDomain Code=-1001")
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions().count("info"), 11)
        self.assertEqual(self.actions().count("submit"), 1)
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})
        self.assertNotIn("synthetic", json.dumps(self.events))

    def test_submit_timeout_adopts_delayed_history_without_resubmitting(self):
        def response(action, arguments, options):
            if action == "submit":
                return self.result(error="NSURLErrorDomain error -1001", code=1)
            if action == "history":
                entries = [] if self.actions().count("history") == 1 else [self.history_entry()]
                return self.result({"history": entries})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "history", "info"])
        self.assertEqual(self.events, [{"event": "upload-started"}, {"event": "submission", "id": ID},
                                       {"event": "accepted", "id": ID}])

    def test_subprocess_submit_timeout_also_reconciles(self):
        def response(action, arguments, options):
            if action == "submit":
                raise subprocess.TimeoutExpired(arguments, options["timeout"], output=KEY)
            if action == "history":
                return self.result({"history": [self.history_entry()]})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "info"])

    def test_submit_retries_only_after_three_successful_empty_histories(self):
        def response(action, arguments, options):
            if action == "submit" and self.actions().count("submit") == 1:
                return self.result(error="NSURLErrorDomain Code=-1001", code=1)
            if action == "history":
                return self.result({"history": [self.history_entry(name="Other.zip"),
                                                 self.history_entry(seconds=-240)]})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "history", "history", "submit", "info"])

    def test_subprocess_timeout_preserves_an_already_emitted_submission_id(self):
        def response(action, arguments, options):
            if action == "submit":
                raise subprocess.TimeoutExpired(arguments, options["timeout"],
                                                output=json.dumps({"id": ID}).encode(), stderr=KEY)
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "info"])
        self.assertEqual(self.events, [{"event": "upload-started"}, {"event": "submission", "id": ID},
                                       {"event": "accepted", "id": ID}])

    def test_missing_submission_stops_after_three_uploads(self):
        self.response = lambda action, args, opts: (
            self.result({"history": []}) if action == "history" else
            self.result(error="NSURLErrorDomain Code=-1001", code=1))
        self.assert_failure("attempts")
        self.assertEqual(self.actions().count("submit"), 3)
        self.assertEqual(self.actions().count("history"), 9)
        self.assertEqual(self.events, [{"event": "upload-started"}])

    def test_history_unavailable_invalid_or_ambiguous_stops_without_upload(self):
        histories = [
            (self.result(error="Authentication failed", code=1), "history", []),
            (self.result({}), "history", []),
            (self.result({"history": [self.history_entry(submission_id="synthetic-key-id")]}), "history", []),
            (self.result({"history": [self.history_entry(), self.history_entry(OTHER_ID)]}),
             "ambiguous", [ID, OTHER_ID]),
        ]
        for history, reason, ids in histories:
            with self.subTest(reason=reason, ids=ids):
                self.calls.clear()
                self.events.clear()
                self.runner.ids.clear()
                self.runner.upload_started = False
                self.runner.delay = 5
                self.response = lambda action, args, opts: (
                    history if action == "history" else
                    self.result(error="NSURLErrorDomain Code=-1001", code=1))
                self.assert_failure(reason)
                self.assertEqual(self.actions(), ["submit", "history"])
                self.assertEqual([event["id"] for event in self.events if event["event"] == "submission"], ids)

    def test_history_window_includes_first_upload_after_a_retry(self):
        def response(action, arguments, options):
            if action == "submit":
                return self.result(error="NSURLErrorDomain Code=-1001", code=1)
            if action == "history":
                entries = [] if self.actions().count("submit") == 1 else [self.history_entry(seconds=1)]
                return self.result({"history": entries})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions().count("submit"), 2)
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})

    def test_submit_id_is_retained_even_if_command_fails(self):
        self.response = lambda *args: self.result({"id": ID}, code=1)
        self.assert_failure("request")
        self.assertEqual(self.actions(), ["submit"])
        self.assertEqual(self.events, [{"event": "upload-started"}, {"event": "submission", "id": ID}])

    def test_transient_submit_with_id_goes_directly_to_info(self):
        self.response = lambda action, args, opts: (
            self.result({"id": ID}, code=1, error="NSURLErrorDomain Code=-1001") if action == "submit"
            else self.result({"id": ID, "status": "Accepted"}))
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "info"])

    def test_status_failures_stop_without_retry_or_untrusted_output(self):
        responses = [
            (self.result({"id": ID, "status": "Invalid"}), "rejected"),
            (self.result({"id": ID, "status": "Rejected"}, code=1,
                         error="NSURLErrorDomain Code=-1001"), "rejected"),
            (self.result({"id": OTHER_ID, "status": "Accepted"}), "status"),
            (self.result({"id": ID, "status": "synthetic-private-key-bytes"}), "status"),
            (self.result({"id": ID, "status": "Accepted"}, code=1), "request"),
            (self.result(code=1, error="NSURLErrorDomain Code=-1200"), "request"),
            (self.result(code=1, error="Credential unavailable"), "request"),
        ]
        for response, reason in responses:
            with self.subTest(reason=reason):
                self.calls.clear()
                self.runner.delay = 5
                self.response = lambda action, args, opts: self.result({"id": ID}) if action == "submit" else response
                self.assert_failure(reason)
                self.assertEqual(self.actions(), ["submit", "info"])

    def test_approval_denial_does_not_reconcile_or_retry(self):
        self.runner = self.make_runner(credential=True)
        self.target_started = False
        self.response = lambda *args: self.result(code=1)
        self.assert_failure("approval")
        self.assertEqual(self.actions(), ["submit"])

    def test_profile_mode_needs_no_key_file_or_pipe(self):
        self.runner.notarize()
        self.assertTrue(all(arguments[0] == "xcrun" for arguments, _, _ in self.calls))
        self.assertTrue(all("--keychain-profile" in arguments for arguments, _, _ in self.calls))
        self.assertFalse(hasattr(self.runner, "key"))
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})

    def test_transient_history_errors_do_not_count_as_empty_snapshots(self):
        def response(action, arguments, options):
            if action == "submit" and self.actions().count("submit") == 1:
                return self.result(error="NSURLErrorDomain Code=-1001", code=1)
            if action == "history":
                if self.actions().count("history") in (1, 3, 5):
                    return self.result(error="NSURLErrorDomain Code=-1005", code=1)
                return self.result({"history": []})
            return self.success(action, arguments, options)
        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit"] + ["history"] * 6 + ["submit", "info"])

    def test_clock_skew_before_start_is_ambiguous_after_start_is_adopted(self):
        for seconds, expected in ((-60, "ambiguous"), (-180, "ambiguous"), (180, None)):
            with self.subTest(seconds=seconds):
                self.elapsed = 0
                self.calls.clear()
                self.events.clear()
                self.runner = self.make_runner()
                self.response = lambda action, args, opts: (
                    self.result(error="NSURLErrorDomain Code=-1001", code=1) if action == "submit" else
                    self.result({"history": [self.history_entry(seconds=seconds)]}) if action == "history" else
                    self.result({"id": ID, "status": "Accepted"}))
                if expected:
                    self.assert_failure(expected)
                    self.assertEqual(self.actions(), ["submit", "history"])
                else:
                    self.runner.notarize()
                self.assertEqual(self.events[1], {"event": "submission", "id": ID})

    def test_history_timeout_preserves_a_matching_id_in_partial_output(self):
        def response(action, arguments, options):
            if action == "submit":
                return self.result(error="NSURLErrorDomain Code=-1001", code=1)
            if action == "history":
                raise subprocess.TimeoutExpired(arguments, options["timeout"],
                    output=json.dumps({"history": [self.history_entry()]}).encode())
            return self.success(action, arguments, options)
        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "info"])
        self.assertEqual(self.events[1], {"event": "submission", "id": ID})

    def test_started_time_rounds_down_to_the_second(self):
        self.elapsed = 0.75
        self.response = lambda action, args, opts: (
            self.result(error="NSURLErrorDomain Code=-1001", code=1) if action == "submit" else
            self.result({"history": [self.history_entry(seconds=0)]}) if action == "history" else
            self.result({"id": ID, "status": "Accepted"}))
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "info"])

    def test_adopted_in_progress_deadline_has_incomplete_upload_diagnostic(self):
        self.response = lambda action, args, opts: (
            self.result(error="NSURLErrorDomain Code=-1001", code=1) if action == "submit" else
            self.result({"history": [self.history_entry()]}) if action == "history" else
            self.result({"id": ID, "status": "In Progress"}))
        self.assert_failure("adopted-incomplete")
        self.assertEqual(self.elapsed, 1800)
        self.assertEqual(self.events, [{"event": "upload-started"}, {"event": "submission", "id": ID}])

    def test_summary_preserves_ids_before_partial_line_and_avoids_history_after_approval_failure(self):
        response = self.directory / "response.jsonl"
        response.write_text(json.dumps({"event": "submission", "id": ID}) + '\n{"event":', encoding="utf-8")
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(MODULE.summarize(response, ids_only=True), 0)
        self.assertIn(ID, output.getvalue())
        response.write_text(json.dumps({"event": "failed", "reason": "approval"}), encoding="utf-8")
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(MODULE.summarize(response), 1)
        self.assertIn("credential delivery", error.getvalue())
        self.assertNotIn("history", error.getvalue())

    def test_history_approval_failure_after_upload_keeps_history_guidance(self):
        self.runner = self.make_runner(credential=True)
        def response(action, arguments, options):
            self.target_started = False  # The next helper request never reaches its target.
            return self.result(error="NSURLErrorDomain Code=-1001", code=1)
        self.response = response
        self.assert_failure("approval")
        self.assertEqual(self.actions(), ["submit", "history"])
        self.assertEqual(self.events, [{"event": "upload-started"}])
        response_file = self.directory / "response.jsonl"
        records = [{"event": "started"}, *self.events, {"event": "failed", "reason": "approval"}]
        response_file.write_text("\n".join(map(json.dumps, records)), encoding="utf-8")
        error = io.StringIO()
        with redirect_stderr(error):
            self.assertEqual(MODULE.summarize(response_file), 1)
        self.assertIn("after an upload started", error.getvalue())
        self.assertIn("inspect notarytool history", error.getvalue())
        self.assertNotIn("did not start", error.getvalue())

    def test_helper_waiting_at_deadline_is_not_reported_as_approval_denial(self):
        self.runner = self.make_runner(credential=True)
        self.elapsed = 1750
        self.target_started = False
        def response(action, arguments, options):
            self.elapsed += options["timeout"]
            raise subprocess.TimeoutExpired(arguments, options["timeout"])
        self.response = response
        self.assert_failure("deadline")
        self.assertEqual(self.elapsed, 1800)
        self.assertEqual(self.events, [])


if __name__ == "__main__":
    unittest.main()
