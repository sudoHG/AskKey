"""Run build-app.sh against synthetic build products and tools to check the CloudKit option."""

import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("cloudkit_signing_tests",
                                              ROOT / "Tests/Automation/test_cloudkit_signing.py")
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)
APP = Path(".build/AskKeyApp.app")
NESTED_TARGETS = [
    ".build/release/askkey",
    ".build/AskKeyApp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate",
    ".build/AskKeyApp.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app",
    ".build/AskKeyApp.app/Contents/Frameworks/Sparkle.framework",
    ".build/AskKeyApp.app/Contents/Helpers/askkey",
    ".build/AskKeyApp.app/Contents/Helpers/AskKey_AskKeyHelper.bundle",
]


class BuildAppCloudKitTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-build-app-cloudkit-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.root = self.directory / "checkout"
        scripts = self.root / "scripts"
        scripts.mkdir(parents=True)
        for name in ("build-app.sh", "cloudkit-signing.py", "sparkle-public-key.txt"):
            shutil.copyfile(ROOT / "scripts" / name, scripts / name)
        stubs = {
            "release-gate.py": "import sys\nsys.exit(0)\n",
            "product-version.sh": "echo 9.9.9\n",
            "check_sdk_markers.py": "import sys\nsys.exit(0)\n",
            "compile-app-icon.sh": "#!/bin/bash\nexit 0\n",
        }
        for name, text in stubs.items():
            (scripts / name).write_text(text, encoding="utf-8")
        (scripts / "compile-app-icon.sh").chmod(0o755)
        (self.root / "LICENSE").write_text("Synthetic license\n", encoding="utf-8")
        for config, cli in (("Release", "release"), ("Debug", "debug")):
            self.make_products(config, cli)
        self.trace = self.directory / "calls.jsonl"
        tools = fixtures.install_stubs(self.directory)
        self.environment = fixtures.stub_environment(self.directory, tools, self.trace)
        self.profile = self.directory / "Synthetic.provisionprofile"
        self.write_profile(fixtures.synthetic_profile())

    def make_products(self, config, cli):
        products = self.root / ".derivedData/local-app/Build/Products" / config
        resources = products / "AskKey_AskKeyAppKit.bundle/Contents/Resources"
        (resources / "en.lproj").mkdir(parents=True)
        (resources / "MenuBarIcon.png").write_bytes(b"synthetic icon")
        for executable in ("AskKeyApp", "AskKeyE2EApp"):
            (products / executable).write_bytes(b"synthetic executable")
        sparkle = products / "Sparkle.framework/Versions/B"
        (sparkle / "Updater.app/Contents").mkdir(parents=True)
        (sparkle / "Autoupdate").write_bytes(b"synthetic autoupdate")
        (sparkle / "XPCServices").mkdir()
        helper = self.root / ".build" / cli
        (helper / "AskKey_AskKeyHelper.bundle").mkdir(parents=True)
        (helper / "askkey").write_bytes(b"synthetic helper")

    def write_profile(self, profile):
        self.profile.write_bytes(plistlib.dumps(profile))

    def run_build(self, mode, profile=True, **environment):
        variables = dict(self.environment, **environment)
        if mode in ("Local", "Release"):
            variables.update(ASKKEY_CODESIGN_IDENTITY=fixtures.IDENTITY_NAME, ASKKEY_APPLE_TEAM_ID=fixtures.TEAM)
        if mode == "Release":
            variables["ASKKEY_RELEASES_ENABLED"] = "true"
        if profile:
            variables["ASKKEY_PROVISIONING_PROFILE"] = str(self.profile)
        return subprocess.run(["bash", str(self.root / "scripts/build-app.sh"), mode], cwd=self.directory,
                              env=variables, text=True, capture_output=True, timeout=120)

    def calls(self):
        return fixtures.read_trace(self.trace)

    def signings(self):
        record = self.directory / "tool-state/signing.jsonl"
        return [json.loads(line) for line in record.read_text().splitlines()] if record.exists() else []

    def app(self, *parts):
        return self.root / APP / "Contents" / Path(*parts)

    def assertNoSecrets(self, result):
        for secret in (fixtures.TEAM, fixtures.IDENTITY_NAME, fixtures.CERTIFICATE_SHA1):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_option_is_refused_outside_local_before_any_work(self):
        for mode, message in (("Release", "until #269 stage 4 ships the iPhone app"),
                              ("Debug", "signed ad hoc, which cannot carry the CloudKit and push entitlements"),
                              ("E2E", "signed ad hoc, which cannot carry the CloudKit and push entitlements")):
            with self.subTest(mode=mode):
                result = self.run_build(mode)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("ASKKEY_PROVISIONING_PROFILE is refused", result.stderr)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.calls(), [])
                self.assertFalse((self.root / APP).exists())
                self.assertFalse((self.root / ".build/cloudkit-signing").exists())
        result = self.run_build("Debug", profile=False, ASKKEY_PROVISIONING_PROFILE="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("ASKKEY_PROVISIONING_PROFILE is refused in Debug builds", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_empty_or_relative_profile_path_in_local(self):
        result = self.run_build("Local", profile=False, ASKKEY_PROVISIONING_PROFILE="")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("must name a provisioning profile file", result.stderr)
        self.assertFalse([call for call in self.calls() if call[0] in ("swift", "xcodebuild", "codesign")])
        # run_build starts the script outside the checkout, so a relative path resolves against that directory.
        result = self.run_build("Local", profile=False, ASKKEY_PROVISIONING_PROFILE=self.profile.name)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.app("embedded.provisionprofile").read_bytes(), self.profile.read_bytes())

    def test_local_build_embeds_and_declares_before_signing_and_reads_back(self):
        result = self.run_build("Local")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNoSecrets(result)
        signings = self.signings()
        self.assertEqual([entry["target"] for entry in signings], NESTED_TARGETS + [str(APP)])
        for entry in signings:
            self.assertTrue(entry["profile"], f"{entry['target']} was signed before the profile was embedded")
            self.assertEqual(entry["container"], fixtures.CONTAINER)
            self.assertEqual(entry["entitlements"], entry["target"] == str(APP), entry["target"])
        sign_calls = [call for call in self.calls() if call[0] == "codesign" and "--sign" in call]
        self.assertTrue(all(call[call.index("--sign") + 1] == fixtures.CERTIFICATE_SHA1 for call in sign_calls))
        self.assertTrue(all({"--options", "runtime", "--timestamp"} <= set(call) for call in sign_calls))
        self.assertEqual(self.app("embedded.provisionprofile").read_bytes(), self.profile.read_bytes())
        info = plistlib.loads(self.app("Info.plist").read_bytes())
        self.assertEqual(info["AskKeyCloudKitContainer"], fixtures.CONTAINER)
        self.assertEqual(info["CFBundleIdentifier"], fixtures.BUNDLE_ID)
        self.assertTrue(info["AskKeyLocalTesting"])
        generated = self.root / ".build/cloudkit-signing/AskKeyApp.entitlements"
        self.assertEqual(plistlib.loads(generated.read_bytes()), fixtures.ENTITLEMENTS)
        self.assertIn("Read back: the signed entitlements and the embedded provisioning profile", result.stdout)
        self.assertIn("Developer ID for com.sudohg.askkey.app", result.stdout)

    def test_steps_run_in_order(self):
        result = self.run_build("Local")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()

        def first(predicate):
            return next(index for index, call in enumerate(calls) if predicate(call))

        decode = first(lambda call: call[:2] == ["security", "cms"])
        build = first(lambda call: call[0] == "xcodebuild")
        sign_app = first(lambda call: call[0] == "codesign" and "--sign" in call and call[-1] == str(APP))
        read_entitlements = first(lambda call: call[0] == "codesign" and "-d" in call and "--entitlements" in call)
        read_certificate = first(lambda call: any(part.startswith("--extract-certificates=") for part in call))
        strict = first(lambda call: call[:4] == ["codesign", "--verify", "--strict", "--deep"])
        self.assertLess(decode, build, "the profile is checked before building")
        self.assertLess(sign_app, read_entitlements)
        self.assertLess(sign_app, read_certificate)
        self.assertLess(max(read_entitlements, read_certificate), strict)

    def test_profile_problems_stop_the_build_before_compiling(self):
        cases = (
            (fixtures.synthetic_profile(expires=fixtures.now() - fixtures.timedelta(days=1)), "expired on"),
            (fixtures.synthetic_profile(DeveloperCertificates=[b"another synthetic certificate"]),
             "does not list the signing certificate"),
            (fixtures.synthetic_profile(**{"com.apple.application-identifier": "FAKETEAM01.com.example.other"}),
             "App ID"),
        )
        for profile, message in cases:
            with self.subTest(message=message):
                self.trace.unlink(missing_ok=True)
                self.write_profile(profile)
                result = self.run_build("Local")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNoSecrets(result)
                self.assertFalse([call for call in self.calls() if call[0] in ("swift", "xcodebuild", "codesign")])
        self.trace.unlink(missing_ok=True)
        self.profile.unlink()
        result = self.run_build("Local")
        self.assertIn("must name a provisioning profile file", result.stderr)
        self.assertEqual(result.returncode, 1)

    def test_read_back_failures_stop_before_strict_verification(self):
        for failure, message in (
            ("signed-entitlements", "signed entitlements differ from the CloudKit entitlements in: "
                                    "com.apple.developer.aps-environment"),
            ("embedded-profile", "not the one that was checked"),
            ("unsealed", "not the one sealed by the App's signature"),
            ("certificate", "not signed with the certificate that was checked"),
        ):
            with self.subTest(failure=failure):
                self.trace.unlink(missing_ok=True)
                result = self.run_build("Local", CLOUDKIT_TEST_FAILURE=failure)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("The signed App does not match the intended CloudKit signing", result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNoSecrets(result)
                self.assertFalse([call for call in self.calls() if call[:2] == ["codesign", "--verify"]])

    def test_every_mode_without_the_option_is_unchanged(self):
        info = {}
        for mode in ("Local", "Release", "Debug", "E2E"):
            with self.subTest(mode=mode):
                self.trace.unlink(missing_ok=True)
                (self.directory / "tool-state/signing.jsonl").unlink(missing_ok=True)
                result = self.run_build(mode, profile=False)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                cli = ".build/release/askkey" if mode in ("Local", "Release") else ".build/debug/askkey"
                self.assertEqual([entry["target"] for entry in self.signings()],
                                 [cli] + NESTED_TARGETS[1:] + [str(APP)])
                self.assertFalse([entry for entry in self.signings() if entry["entitlements"] or entry["profile"]])
                self.assertFalse([call for call in self.calls() if call[0] == "security"])
                self.assertFalse([call for call in self.calls() if "--entitlements" in call])
                self.assertFalse(self.app("embedded.provisionprofile").exists())
                self.assertFalse((self.root / ".build/cloudkit-signing").exists())
                info[mode] = plistlib.loads(self.app("Info.plist").read_bytes())
                self.assertNotIn("AskKeyCloudKitContainer", info[mode])
                sign_calls = [call for call in self.calls() if call[0] == "codesign" and "--sign" in call]
                identity = fixtures.IDENTITY_NAME if mode in ("Local", "Release") else "-"
                self.assertTrue(all(call[call.index("--sign") + 1] == identity for call in sign_calls))
        self.assertEqual(self.run_build("Local").returncode, 0)
        with_option = plistlib.loads(self.app("Info.plist").read_bytes())
        self.assertEqual(with_option.pop("AskKeyCloudKitContainer"), fixtures.CONTAINER)
        self.assertEqual(with_option, info["Local"])

    def test_nested_code_signing_lines_carry_no_entitlements(self):
        source = (ROOT / "scripts/build-app.sh").read_text(encoding="utf-8")
        signing = [line for line in source.splitlines() if line.startswith("codesign ") and "--verify" not in line]
        nested, app = signing[:-1], signing[-1]
        self.assertTrue(all(line.startswith('codesign "${SIGN_OPTIONS[@]}" --sign') for line in nested))
        self.assertEqual(app, 'codesign "${APP_SIGN_OPTIONS[@]}" --sign "$SIGN_IDENTITY" "$APP"')
        self.assertEqual(source.count("APP_SIGN_OPTIONS+=(--entitlements"), 1)


if __name__ == "__main__":
    unittest.main()
