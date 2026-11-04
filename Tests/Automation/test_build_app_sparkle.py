"""Check that build-app.sh embeds Sparkle in every mode and enables it only in Release."""

import base64
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-app.sh"
FEED_URL = "https://askkey.sudohg.com/appcast.xml"
RELEASE_KEYS = {
    "SUFeedURL": ("string", "$SPARKLE_FEED_URL"),
    "SUPublicEDKey": ("string", "$SPARKLE_PUBLIC_KEY"),
    "SURequireSignedFeed": ("bool", "true"),
    "SUVerifyUpdateBeforeExtraction": ("bool", "true"),
    "SUAllowsAutomaticUpdates": ("bool", "false"),
    "SUAutomaticallyUpdate": ("bool", "false"),
    "SUEnableSystemProfiling": ("bool", "false"),
}
KEY_FILE_ERROR = "Release builds require scripts/sparkle-public-key.txt."
KEY_FORMAT_ERROR = "must hold one base64-encoded 32-byte EdDSA public key"
PAST_KEY_CHECK = "synthetic-stop-after-key-check"
DEBUG_BUNDLE = ROOT / ".build/AskKeyApp.app"


class BuildAppSparkleScriptTests(unittest.TestCase):
    def setUp(self):
        self.source = SCRIPT.read_text(encoding="utf-8")

    def release_block(self):
        match = re.search(
            r'^if \[ "\$MODE" = Release \]; then\n  for entry in \\\n(.*?)^  do\n'
            r'    /usr/libexec/PlistBuddy -c "Add :\$entry" "\$APP/Contents/Info\.plist"\n  done\nfi$',
            self.source, re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "expected one Release-only Sparkle key block")
        return match

    def test_feed_url_matches_the_app_policy_and_product_identifiers(self):
        self.assertIn(f'SPARKLE_FEED_URL="{FEED_URL}"', self.source)
        policy = (ROOT / "Sources/AskKeyAppKit/SoftwareUpdate/SoftwareUpdateAvailability.swift").read_text(encoding="utf-8")
        self.assertIn(f'package static let feedURL = "{FEED_URL}"', policy)
        self.assertIn(FEED_URL, (ROOT / "AGENTS.md").read_text(encoding="utf-8"))

    def test_only_release_writes_the_sparkle_keys(self):
        block = self.release_block()
        entries = re.findall(r'^    "(\w+) (\w+) (\S+)"(?: \\)?$', block.group(1), re.MULTILINE)
        self.assertEqual({key: (kind, value) for key, kind, value in entries}, RELEASE_KEYS)
        outside = self.source[:block.start()] + self.source[block.end():]
        self.assertIsNone(re.search(r"\bSU[A-Z]\w+", outside), "Sparkle keys appear outside the Release block")
        for unset in ("SUEnableAutomaticChecks", "SUScheduledCheckInterval"):
            self.assertNotIn(unset, self.source)

    def test_framework_is_embedded_without_xpc_services(self):
        embed = self.source.index('ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"')
        removal = self.source.index('rm -rf "$EMBEDDED_SPARKLE/XPCServices" "$EMBEDDED_SPARKLE/Versions/B/XPCServices"')
        self.assertLess(embed, removal)
        self.assertNotIn('if [ "$MODE"', self.source[self.source.index("# Embed Sparkle"):embed],
                         "the framework must be embedded in every mode")
        self.assertIn("install_name_tool -add_rpath @executable_path/../Frameworks", self.source)

    def test_nested_code_is_signed_inside_out_without_deep(self):
        signing = [line for line in self.source.splitlines()
                   if line.startswith("codesign ") and "--verify" not in line]
        self.assertTrue(signing)
        self.assertFalse([line for line in signing if "--deep" in line], "--deep is only for verification")
        targets = [line.rsplit(" ", 1)[1] for line in signing]
        self.assertEqual(targets, [
            '"$CLI"',
            '"$EMBEDDED_SPARKLE/Versions/B/Autoupdate"',
            '"$EMBEDDED_SPARKLE/Versions/B/Updater.app"',
            '"$EMBEDDED_SPARKLE"',
            '"$APP/Contents/Helpers/askkey"',
            '"$APP/Contents/Helpers/AskKey_AskKeyHelper.bundle"',
            '"$APP"',
        ])
        self.assertIn('codesign --verify --strict --deep "$APP"', self.source)


class BuildAppReleaseKeyTests(unittest.TestCase):
    """Run a copy of the script with stubs, so it stops right after the key check."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-build-app-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(SCRIPT, scripts / "build-app.sh")
        (scripts / "release-gate.py").write_text("import sys\nsys.exit(0)\n", encoding="utf-8")
        (scripts / "product-version.sh").write_text(
            f"echo {PAST_KEY_CHECK} >&2\nexit 3\n", encoding="utf-8"
        )
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("ASKKEY_")}

    def run_script(self, mode, key=None):
        if key is not None:
            (self.root / "scripts/sparkle-public-key.txt").write_text(key, encoding="utf-8")
        environment = dict(self.environment)
        if mode == "Release":
            environment.update({
                "ASKKEY_RELEASES_ENABLED": "true",
                "ASKKEY_CODESIGN_IDENTITY": "Synthetic Identity",
                "ASKKEY_APPLE_TEAM_ID": "SYNTHETIC",
            })
        return subprocess.run(["bash", str(self.root / "scripts/build-app.sh"), mode],
                              env=environment, text=True, capture_output=True, timeout=60)

    def assertPassedKeyCheck(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(KEY_FILE_ERROR, result.stderr)
        self.assertNotIn(KEY_FORMAT_ERROR, result.stderr)
        self.assertTrue(PAST_KEY_CHECK in result.stderr or "80 GiB" in result.stderr, result.stderr)

    def test_release_without_the_key_file_fails_closed(self):
        result = self.run_script("Release")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(KEY_FILE_ERROR, result.stderr)
        self.assertNotIn(PAST_KEY_CHECK, result.stderr)

    def test_release_rejects_a_key_that_is_not_32_base64_bytes(self):
        valid = base64.b64encode(bytes(range(32))).decode()
        for key in ["", "not base64!", base64.b64encode(bytes(31)).decode(),
                    base64.b64encode(bytes(33)).decode(), valid[:-1], f"{valid}\n{valid}\n"]:
            result = self.run_script("Release", key)
            self.assertEqual(result.returncode, 1, f"{key!r}: {result.stderr}")
            self.assertIn(KEY_FORMAT_ERROR, result.stderr)
            self.assertNotIn(PAST_KEY_CHECK, result.stderr)

    def test_release_accepts_one_base64_32_byte_key(self):
        key = base64.b64encode(bytes(range(32))).decode()
        self.assertPassedKeyCheck(self.run_script("Release", f"{key}\n"))

    def test_debug_needs_no_key(self):
        self.assertPassedKeyCheck(self.run_script("Debug"))


@unittest.skipUnless(
    (DEBUG_BUNDLE / "Contents/Info.plist").is_file()
    and plistlib.loads((DEBUG_BUNDLE / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier")
    == "com.sudohg.askkey.app.dev",
    "run `bash scripts/build-app.sh Debug` first to check its output",
)
class DebugBundleTests(unittest.TestCase):
    """Check the bundle written by `bash scripts/build-app.sh Debug`."""

    def test_debug_bundle_has_no_sparkle_keys(self):
        info = plistlib.loads((DEBUG_BUNDLE / "Contents/Info.plist").read_bytes())
        self.assertEqual([key for key in info if key.startswith("SU")], [])

    def test_debug_bundle_embeds_sparkle_without_xpc_services(self):
        framework = DEBUG_BUNDLE / "Contents/Frameworks/Sparkle.framework"
        self.assertTrue((framework / "Versions/B/Sparkle").is_file())
        self.assertTrue((framework / "Versions/B/Autoupdate").is_file())
        self.assertTrue((framework / "Versions/B/Updater.app").is_dir())
        self.assertEqual(list(DEBUG_BUNDLE.rglob("*.xpc")), [])
        self.assertEqual(list(DEBUG_BUNDLE.rglob("XPCServices")), [])

    def test_debug_bundle_signature_and_rpaths(self):
        verify = subprocess.run(["codesign", "--verify", "--strict", "--deep", str(DEBUG_BUNDLE)],
                                text=True, capture_output=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        load_commands = subprocess.run(["otool", "-l", str(DEBUG_BUNDLE / "Contents/MacOS/AskKeyApp")],
                                       text=True, capture_output=True, check=True).stdout
        rpaths = re.findall(r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+) \(offset \d+\)", load_commands)
        self.assertIn("@executable_path/../Frameworks", rpaths)
        self.assertEqual([path for path in rpaths if path.startswith(str(ROOT))], [])


if __name__ == "__main__":
    unittest.main()
