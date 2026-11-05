"""Check the signed appcast step of release packaging with synthetic tools and keys."""

import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_release_harness",
                                              ROOT / "Tests/Automation/test_package_release.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
CRITICAL_UPDATE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}criticalUpdate"


class PackageReleaseAppcastTests(unittest.TestCase):
    def setUp(self):
        # Reuse the packaging harness by composition so its tests do not run twice.
        self.harness = package.PackageReleaseTests()
        self.harness.setUp()
        self.addCleanup(self.harness.doCleanups)

    def calls(self, trace):
        return [json.loads(line) for line in trace.read_text().splitlines()]

    def test_notarizing_without_appcast_options_fails_before_work(self):
        harness = self.harness
        environment, trace = harness.mock_tools()
        cases = (
            (["--release-notes", str(harness.release_notes)],
             "--sparkle-key-credential is required when notarizing"),
            (["--sparkle-key-credential", package.SPARKLE_CREDENTIAL],
             "--release-notes is required when notarizing"),
            (["--sparkle-key-credential", package.SPARKLE_CREDENTIAL, "--release-notes",
              str(harness.directory / "missing.md")], "Release notes not found"),
        )
        for arguments, message in cases:
            with self.subTest(message=message):
                result = harness.run_script(*arguments, notarize=True, environment=environment,
                                            appcast=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(trace.exists())
                harness.assert_no_artifacts()
        harness.release_notes.write_text("<!-- lang: en -->\nEnglish only.\n", encoding="utf-8")
        result = harness.run_script(notarize=True, environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Simplified Chinese section", result.stderr)
        self.assertFalse(trace.exists())
        harness.assert_no_artifacts()

    def test_appcast_options_conflict_with_no_notarize(self):
        harness = self.harness
        for arguments in (["--sparkle-key-credential", package.SPARKLE_CREDENTIAL],
                          ["--release-notes", str(harness.release_notes)], ["--critical"]):
            with self.subTest(arguments=arguments):
                result = harness.run_script(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Appcast options and --no-notarize modes conflict", result.stderr)
                harness.assert_no_artifacts()

    def test_bundle_version_mismatch_is_rejected_before_work(self):
        harness = self.harness
        environment, trace = harness.mock_tools()
        plist = harness.app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleVersion"] = "999"
        plist.write_bytes(plistlib.dumps(info))
        result = harness.run_script(notarize=True, environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("App bundle version does not match the product version", result.stderr)
        self.assertFalse(trace.exists())
        harness.assert_no_artifacts()

    @unittest.skipUnless(package.SIGN_UPDATE.is_file(), "needs the resolved Sparkle artifact")
    def test_appcast_runs_through_askkey_and_critical_writes_critical_update(self):
        harness = self.harness
        environment, trace = harness.mock_tools()
        result = harness.run_script("--critical", notarize=True, environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        harness.assert_settings_not_printed(result, environment)
        image = harness.output / f"AskKey-{harness.version}.dmg"
        harness.assert_notarized_artifacts(image)
        appcast = harness.output / "appcast.xml"
        self.assertIn(f"Appcast: {appcast.resolve()}", result.stdout)
        self.assertEqual(result.stdout.count("Approve the Ask Key card to sign the update feed."), 1)
        self.assertIsNotNone(ET.parse(appcast).getroot().find("channel/item/" + CRITICAL_UPDATE))
        requests = [call for call in self.calls(trace) if call[0] == "askkey"]
        self.assertEqual(len(requests), 1)
        call = requests[0]
        self.assertEqual(call[:6], ["askkey", "run", "--wait-for-approval", "--credential",
                                    package.SPARKLE_CREDENTIAL, "--operation-id"])
        self.assertTrue(call[6])
        self.assertEqual(call[7:14], [
            "--caller-name", "AskKey release", "--caller-purpose",
            f"Sign the AskKey {harness.version} update feed", "--", "/bin/bash", "-c",
        ])
        self.assertIn('--ed-key-file "$SPARKLE_ED_KEY_FILE"', call[14])
        self.assertLess(len(call[14].encode()), 512)  # Well below the broker's 4 KiB limit.
        self.assertEqual(call[15:17], ["bash", str(ROOT / "scripts/generate-appcast.py")])
        self.assertEqual(Path(call[17]).name, image.name)
        self.assertEqual(call[18:23], ["--version", harness.version, "--release-notes",
                                       str(harness.release_notes.resolve()), "--output"])
        self.assertEqual(Path(call[23]).name, "appcast.xml")
        self.assertEqual(call[24:], ["--critical"])
        self.assertFalse(any(str(harness.sparkle_key) in argument or harness.sparkle_key_text in argument
                             for argument in call))
        self.assertEqual(list(harness.scratch.iterdir()), [])

    @unittest.skipUnless(package.SIGN_UPDATE.is_file(), "needs the resolved Sparkle artifact")
    def test_appcast_failures_write_nothing(self):
        harness = self.harness
        environment, trace = harness.mock_tools()
        for failure in ("sparkle-approval-denied", "invalid-key"):
            with self.subTest(failure=failure):
                environment["PACKAGE_TEST_FAILURE"] = failure
                if failure == "invalid-key":
                    harness.sparkle_key.write_text("synthetic-invalid-sparkle-key\n", encoding="ascii")
                result = harness.run_script(notarize=True, environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Cannot write the signed appcast", result.stderr)
                harness.assert_settings_not_printed(result, environment)
                self.assertNotIn("synthetic-invalid-sparkle-key", result.stdout + result.stderr)
                self.assertEqual(sum(call[0] == "askkey" for call in self.calls(trace)), 1)
                harness.assert_no_artifacts()
                trace.unlink()


if __name__ == "__main__":
    unittest.main()
