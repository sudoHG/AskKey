"""Regression checks for the optimized app's E2E symbol audit."""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check_release_symbols.sh"


class ReleaseSymbolCheckTests(unittest.TestCase):
    def run_check(self, nm_output="", strings_output="", binary=b"synthetic binary",
                  swift_build_failure=False, inspection_failure=None):
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary)
            tools = temp / "bin"
            tools.mkdir()
            bin_dir = temp / "swift-bin"
            bin_dir.mkdir()
            (bin_dir / "AskKeyApp").write_bytes(binary)
            (temp / "nm-output").write_text(nm_output, encoding="utf-8")
            (temp / "strings-output").write_text(strings_output, encoding="utf-8")

            self.write_command(tools / "swift", """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "build" && "$2" == "-c" && "$3" == "release" && "${SWIFT_BUILD_FAIL-}" == "1" ]]; then
  exit 23
fi
if [[ "$*" == "build -c release --product AskKeyApp --jobs 1" ]]; then
  exit 0
fi
if [[ "$#" -eq 4 && "$1" == "build" && "$2" == "-c" && "$3" == "release" && "$4" == "--show-bin-path" ]]; then
  printf '%s\\n' "$RELEASE_BIN_DIR"
  exit 0
fi
exit 26
""")
            self.write_command(tools / "nm", """#!/usr/bin/env bash
set -euo pipefail
[[ "${INSPECTION_FAIL-}" != nm ]] || exit 24
cat "$NM_OUTPUT_FILE"
""")
            self.write_command(tools / "strings", """#!/usr/bin/env bash
set -euo pipefail
[[ "${INSPECTION_FAIL-}" != strings ]] || exit 25
cat "$STRINGS_OUTPUT_FILE"
""")
            self.write_command(tools / "grep", """#!/usr/bin/env bash
set -euo pipefail
[[ "${INSPECTION_FAIL-}" != grep ]] || exit 2
exec /usr/bin/grep "$@"
""")

            env = os.environ.copy()
            env.update({
                "PATH": f"{tools}{os.pathsep}{env['PATH']}",
                "RELEASE_BIN_DIR": str(bin_dir),
                "NM_OUTPUT_FILE": str(temp / "nm-output"),
                "STRINGS_OUTPUT_FILE": str(temp / "strings-output"),
            })
            if swift_build_failure:
                env["SWIFT_BUILD_FAIL"] = "1"
            if inspection_failure:
                env["INSPECTION_FAIL"] = inspection_failure
            return subprocess.run(["bash", str(SCRIPT)], cwd=ROOT, env=env,
                                  text=True, capture_output=True)

    @staticmethod
    def write_command(path, contents):
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o755)

    def test_clean_binary_is_accepted(self):
        result = self.run_check(nm_output="_main\n", strings_output="AskKey\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_forbidden_symbols_and_strings_are_rejected(self):
        for output_kind in ("nm_output", "strings_output"):
            for forbidden in ("AskKeyTestSupport", "configureE2EAuthentication",
                              "OnboardingBoundaryObserver", "probeHelperProcessForEvidence",
                              "ASKKEY_VISUAL_PROOF", "ASKKEY_DEBUG_AUTHENTICATION"):
                with self.subTest(output_kind=output_kind, forbidden=forbidden):
                    result = self.run_check(**{output_kind: f"prefix_{forbidden}_suffix\n"})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(forbidden, result.stderr)

    def test_empty_binary_is_rejected(self):
        result = self.run_check(binary=b"")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or empty", result.stderr)

    def test_swift_build_failure_is_not_hidden(self):
        result = self.run_check(swift_build_failure=True)
        self.assertEqual(result.returncode, 23)

    def test_inspection_failure_is_not_hidden(self):
        for command, status in (("nm", 24), ("strings", 25), ("grep", 2)):
            with self.subTest(command=command):
                self.assertEqual(self.run_check(inspection_failure=command).returncode, status)


if __name__ == "__main__":
    unittest.main()
