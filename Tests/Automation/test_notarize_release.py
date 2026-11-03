"""Exercise deadlines, reconciliation and expiring keys without credentials or sleeps."""

from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
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
        self.key_path = self.directory / "delivered.p8"
        self.key_path.write_bytes(KEY)
        self.elapsed = 0
        self.sleeps = []
        self.calls = []
        self.events = []
        self.descriptors = []
        self.response = self.success
        self.start = datetime(2026, 1, 1, tzinfo=timezone.utc)
        self.runner = MODULE.Notarizer(
            "AskKey.zip", ["--key", str(self.key_path), "--key-id", "synthetic-key-id",
                           "--issuer", "synthetic-issuer-id"],
            clock=lambda: self.elapsed, sleep=self.sleep, now=lambda: self.start,
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
        if "--key" in arguments:
            descriptor, = options["pass_fds"]
            self.descriptors.append(descriptor)
            self.assertEqual(arguments[arguments.index("--key") + 1], f"/dev/fd/{descriptor}")
            with os.fdopen(os.dup(descriptor), "rb") as pipe:
                self.assertEqual(pipe.read(), KEY)
            self.assertNotIn(str(self.key_path), arguments)
        else:
            self.assertEqual(options["pass_fds"], ())
        return self.response(arguments[2], arguments, options)

    def actions(self):
        return [arguments[2] for arguments, _, _ in self.calls]

    def assert_failure(self, reason):
        with self.assertRaisesRegex(MODULE.Failure, f"^{reason}$"):
            self.runner.notarize()
        self.assertNotIn("synthetic", json.dumps(self.events))
        for descriptor in self.descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def history_entry(self, submission_id=ID, *, name="AskKey.zip", seconds=1):
        return {"id": submission_id, "name": name,
                "createdDate": (self.start + timedelta(seconds=seconds)).isoformat()}

    def test_in_progress_survives_key_expiry_after_five_minutes(self):
        def response(action, arguments, options):
            if self.elapsed >= 300:
                self.key_path.unlink(missing_ok=True)
            if action == "info" and self.elapsed < 350:
                return self.result({"id": ID, "status": "In Progress"})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertFalse(self.key_path.exists())
        self.assertGreater(self.elapsed, 300)
        self.assertEqual(self.actions().count("submit"), 1)
        self.assertEqual(self.sleeps[:5], [5, 10, 20, 40, 60])
        self.assertLessEqual(max(self.sleeps), 60)
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_fast_transient_errors_use_time_budget_not_four_attempts(self):
        for code in ("-1001", "-1003", "-1004", "-1005", "-1006", "-1009"):
            with self.subTest(code=code):
                self.elapsed = 0
                self.calls.clear()
                self.sleeps.clear()
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

    def test_transient_errors_recover_after_key_expiry_without_new_submit(self):
        def response(action, arguments, options):
            if self.elapsed >= 300:
                self.key_path.unlink(missing_ok=True)
            if action == "info" and self.actions().count("info") <= 10:
                return subprocess.CompletedProcess(arguments, 1, b"\xffsynthetic-private-key-bytes",
                                                   b"NSURLErrorDomain Code=-1001")
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertFalse(self.key_path.exists())
        self.assertEqual(self.actions().count("info"), 11)
        self.assertEqual(self.actions().count("submit"), 1)
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})
        self.assertNotIn("synthetic", json.dumps(self.events))

    def test_submit_timeout_adopts_delayed_history_without_resubmitting(self):
        def response(action, arguments, options):
            if action == "submit":
                self.key_path.unlink()
                return self.result(error="NSURLErrorDomain error -1001", code=1)
            if action == "history":
                entries = [] if self.actions().count("history") == 1 else [self.history_entry()]
                return self.result({"history": entries})
            return self.success(action, arguments, options)

        self.response = response
        self.runner.notarize()
        self.assertEqual(self.actions(), ["submit", "history", "history", "info"])
        self.assertEqual(self.events, [{"event": "submission", "id": ID},
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
                                                 self.history_entry(seconds=-60)]})
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
        self.assertEqual(self.events, [{"event": "submission", "id": ID},
                                       {"event": "accepted", "id": ID}])

    def test_missing_submission_stops_after_three_uploads(self):
        self.response = lambda action, args, opts: (
            self.result({"history": []}) if action == "history" else
            self.result(error="NSURLErrorDomain Code=-1001", code=1))
        self.assert_failure("attempts")
        self.assertEqual(self.actions().count("submit"), 3)
        self.assertEqual(self.actions().count("history"), 9)
        self.assertEqual(self.events, [])

    def test_history_unavailable_invalid_or_ambiguous_stops_without_upload(self):
        histories = [
            (self.result(error="NSURLErrorDomain Code=-1001", code=1), "history", []),
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
                self.response = lambda action, args, opts: (
                    history if action == "history" else
                    self.result(error="NSURLErrorDomain Code=-1001", code=1))
                self.assert_failure(reason)
                self.assertEqual(self.actions(), ["submit", "history"])
                self.assertEqual([event["id"] for event in self.events], ids)

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
        self.assertEqual(self.events, [{"event": "submission", "id": ID}])

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
            (self.result(code=1, error="Cannot read /dev/fd/3"), "request"),
        ]
        for response, reason in responses:
            with self.subTest(reason=reason):
                self.calls.clear()
                self.response = lambda action, args, opts: self.result({"id": ID}) if action == "submit" else response
                self.assert_failure(reason)
                self.assertEqual(self.actions(), ["submit", "info"])

    def test_key_unavailable_at_start_fails_before_any_request(self):
        self.key_path.unlink()
        with self.assertRaisesRegex(MODULE.Failure, "credentials"):
            MODULE.Notarizer("AskKey.zip", ["--key", str(self.key_path)], run=self.tool)
        self.assertEqual(self.calls, [])

    def test_profile_mode_needs_no_key_file_or_pipe(self):
        self.runner.auth = ["--keychain-profile", "synthetic-profile"]
        self.runner.key = None
        self.runner.notarize()
        self.assertTrue(all(options["pass_fds"] == () for _, options, _ in self.calls))
        self.assertEqual(self.events[-1], {"event": "accepted", "id": ID})


if __name__ == "__main__":
    unittest.main()
