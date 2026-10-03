"""Regression checks for false-green delivery receipts; no UI pass is fabricated."""
import copy
import importlib.util
import json
import pathlib
import subprocess
import unittest
import tempfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("gate", ROOT / "scripts/e2e-gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class E2EGateTests(unittest.TestCase):
    def setUp(self):
        self.summary = {"passedTests": 2, "failedTests": 0, "skippedTests": 0, "result": "Passed"}
        self.tree = {"testNodes": [{"nodeType": "Test Suite", "children": [
            {"nodeType": "Test Case", "name": "testA()", "result": "Passed"},
            {"nodeType": "Test Case", "name": "testB()", "result": "Passed"},
        ]}]}

    def test_complete_required_set_is_accepted(self):
        gate.validate_results(self.summary, self.tree, ["testA", "testB"])

    def test_pass_count_cannot_hide_missing_case(self):
        with self.assertRaises(ValueError):
            gate.validate_results(self.summary, self.tree, ["testA", "testC"])

    def test_empty_run_and_empty_manifest_are_rejected(self):
        for tree, required in [({"testNodes": []}, ["testA"]), (self.tree, [])]:
            with self.assertRaises(ValueError):
                gate.validate_results(self.summary, tree, required)

    def test_skips_and_expected_failures_cannot_count_as_pass(self):
        for result in ["Skipped", "Expected Failure", "Failed"]:
            tree = copy.deepcopy(self.tree)
            tree["testNodes"][0]["children"][1]["result"] = result
            with self.assertRaises(ValueError):
                gate.validate_results(self.summary, tree, ["testA"])

    def test_bootstrap_failure_is_rejected(self):
        summary = dict(self.summary, failedTests=1, result="Failed")
        with self.assertRaises(ValueError):
            gate.validate_results(summary, self.tree, ["testA", "testB"])

    def test_new_attempt_invalidates_previous_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            receipt = root / "Tests/UI/output/passing-receipt.json"
            receipt.parent.mkdir(parents=True)
            receipt.write_text("previous run")
            with patch.object(gate, "ROOT", root):
                gate.invalidate()
            self.assertFalse(receipt.exists())

    def test_empty_result_bundle_cannot_be_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            (output / "basic-flows.xcresult").mkdir()
            with self.assertRaises(gate.subprocess.CalledProcessError):
                gate.load_results(output)

    def test_changed_source_invalidates_recorded_fingerprint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True, capture_output=True)
            source = root / "Sources/Fixture.swift"
            source.parent.mkdir()
            source.write_text("let fixture = 1\n")
            receipt = root / "Tests/UI/output/passing-receipt.json"
            receipt.parent.mkdir(parents=True)
            with patch.object(gate, "ROOT", root):
                original_fingerprint = gate.fingerprint()
                receipt.write_text(json.dumps({"sourceFingerprint": original_fingerprint}))
                source.write_text("let fixture = 2\n")
                self.assertNotEqual(gate.fingerprint(), original_fingerprint)
                # Reject stale source before consulting any result-bundle fields.
                with self.assertRaisesRegex(SystemExit, "Source changed; the E2E receipt is stale"):
                    gate.verify()

    def test_sidecar_json_must_match_original_result_bundle(self):
        for mismatched in ["summary.json", "tests.json"]:
            with self.subTest(mismatched=mismatched), tempfile.TemporaryDirectory() as directory:
                output = pathlib.Path(directory)
                (output / "basic-flows.xcresult").mkdir()
                (output / "summary.json").write_text(json.dumps(self.summary))
                (output / "tests.json").write_text(json.dumps(self.tree))
                actual_summary = copy.deepcopy(self.summary)
                actual_tree = copy.deepcopy(self.tree)
                if mismatched == "summary.json":
                    actual_summary.update(failedTests=1, result="Failed")
                else:
                    actual_tree["testNodes"][0]["children"][1]["result"] = "Skipped"
                # Only substitute xcresulttool's read boundary; the production
                # JSON comparison must reject the apparently passing sidecar.
                with patch.object(gate.subprocess, "check_output", side_effect=[
                    json.dumps(actual_summary), json.dumps(actual_tree)
                ]):
                    with self.assertRaisesRegex(ValueError, f"{mismatched} does not match the original xcresult"):
                        gate.load_results(output)


if __name__ == "__main__":
    unittest.main()
