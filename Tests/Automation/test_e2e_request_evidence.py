"""Exercise the actual Swift E2E reader against real atomic-publication files."""
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class E2ERequestEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="askkey-e2e-reader-")
        cls.addClassCleanup(cls.build.cleanup)
        cls.binary = pathlib.Path(cls.build.name) / "request-evidence-tests"
        compilation = subprocess.run([
            "xcrun", "swiftc",
            str(ROOT / "Tests/AskKeyE2ETests/E2ERequestEvidenceReader.swift"),
            str(ROOT / "Tests/Automation/Fixtures/E2ERequestEvidenceChecks.swift"),
            "-o", str(cls.binary),
        ], capture_output=True, text=True, timeout=60)
        if compilation.returncode != 0:
            raise RuntimeError(
                f"Swift evidence-reader compilation failed ({compilation.returncode}):\n"
                f"stdout:\n{compilation.stdout}\nstderr:\n{compilation.stderr}"
            )

    def check_scenario(self, scenario):
        result = subprocess.run(
            [str(self.binary), scenario], capture_output=True, text=True, timeout=10
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_incomplete_atomic_temporary_file_is_not_a_request(self):
        self.check_scenario("incomplete-temporary")

    def test_atomic_temporary_file_can_disappear_after_enumeration(self):
        self.check_scenario("disappearing-temporary")

    def test_only_published_requests_count_even_if_temporary_json_is_valid(self):
        self.check_scenario("valid-temporary")

    def test_published_request_can_be_atomically_replaced_before_reading(self):
        self.check_scenario("replaced-published")

    def test_malformed_published_evidence_is_reported(self):
        self.check_scenario("malformed-published")

    def test_missing_published_evidence_is_reported(self):
        self.check_scenario("missing-published")


if __name__ == "__main__":
    unittest.main()
