"""Check real synthetic DMG packaging and fail-closed notarization gates."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/package-release.sh"
SIGNING_ENV = ("ASKKEY_CODESIGN_IDENTITY", "ASKKEY_APPLE_TEAM_ID", "ASKKEY_NOTARY_PROFILE")
SUBMISSION_ID = "12345678-1234-1234-1234-123456789abc"
NOTARY_CREDENTIAL = "synthetic-notary"
NOTARY_SHELL = (
    'xcrun notarytool submit "$1" --key "$PRIVATE_KEY_FILE" --key-id "$KEY_ID" '
    '--issuer "$ISSUER_ID" --wait --output-format json'
)
SYNTHETIC_MAPPINGS = {
    "PRIVATE_KEY_FILE": "synthetic-private-key-file",
    "KEY_ID": "synthetic-key-id",
    "ISSUER_ID": "synthetic-issuer-id",
}


def diskutil_image_attach_available():
    if shutil.which("diskutil") is None:
        return False
    result = subprocess.run(["diskutil", "help", "image", "attach"],
                            capture_output=True, text=True)
    return result.returncode == 0


class PackageReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-package-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.app = self.directory / "Fixture App.app"
        self.output = self.directory / "release output"
        self.scratch = self.directory / "scratch"
        self.scratch.mkdir()
        self.version = subprocess.check_output(
            ["bash", str(ROOT / "scripts/product-version.sh")], text=True
        ).strip()
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("ASKKEY_")}
        self.environment["TMPDIR"] = str(self.scratch)
        self.make_app()

    def make_app(self, version=None, identifier="com.sudohg.askkey.app", signed=True):
        if self.app.exists():
            shutil.rmtree(self.app)
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Resources").mkdir()
        executable = contents / "MacOS/Fixture"
        shutil.copyfile("/usr/bin/true", executable)
        executable.chmod(0o755)
        (contents / "Resources/fixture.txt").write_text("synthetic fixture", encoding="utf-8")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump({
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": identifier,
                "CFBundleName": "Fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": version or self.version,
                "CFBundleVersion": version or self.version,
            }, stream)
        if signed:
            subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)],
                           check=True, text=True, capture_output=True)

    def run_script(self, *arguments, notarize=False, environment=None, output=True):
        command = ["bash", str(SCRIPT), "--app", str(self.app)]
        if output:
            command.extend(["--output", str(self.output)])
        if not notarize:
            command.append("--no-notarize")
        return subprocess.run(command + list(map(str, arguments)), cwd=self.directory,
                              env=environment or self.environment, text=True,
                              capture_output=True, timeout=120)

    def assert_no_artifacts(self):
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def assert_checksum(self, image):
        checksum = image.with_name(image.name + ".sha256")
        expected = hashlib.sha256(image.read_bytes()).hexdigest()
        self.assertEqual(checksum.read_text(), f"{expected}  {image.name}\n")
        result = subprocess.run(["shasum", "-a", "256", "-c", checksum.name],
                                cwd=self.output, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"{image.name}: OK", result.stdout)

    def attach_image(self, image, mountpoint):
        if diskutil_image_attach_available():
            result = subprocess.run(
                ["diskutil", "image", "attach", "--nobrowse", "--readOnly",
                 "--mountPoint", str(mountpoint), str(image)],
                text=True, capture_output=True)
            if result.returncode == 0:
                return
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint",
                        str(mountpoint), str(image)], check=True, text=True,
                       capture_output=True)

    def eject_image(self, mountpoint):
        if shutil.which("diskutil") is not None:
            result = subprocess.run(["diskutil", "eject", str(mountpoint)],
                                    text=True, capture_output=True)
            if result.returncode == 0:
                return
        subprocess.run(["hdiutil", "detach", str(mountpoint)], check=True,
                       text=True, capture_output=True)

    def test_unnotarized_dmg_mounts_with_app_and_applications_link(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        image = self.output / f"AskKey-{self.version}-unnotarized.dmg"
        self.assertTrue(image.is_file())
        self.assertIn(f"DMG: {image.resolve()}", result.stdout)
        self.assertIn("Notarized: false", result.stdout)
        mountpoint = self.directory / "mounted"
        mountpoint.mkdir()
        self.attach_image(image, mountpoint)
        try:
            self.assertTrue((mountpoint / "Ask Key.app").is_dir())
            applications = mountpoint / "Applications"
            self.assertTrue(applications.is_symlink())
            self.assertEqual(os.readlink(applications), "/Applications")
            subprocess.run(["codesign", "--verify", "--strict", "--deep",
                            str(mountpoint / "Ask Key.app")], check=True,
                           text=True, capture_output=True)
        finally:
            self.eject_image(mountpoint)
        self.assert_checksum(image)
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_version_mismatch_is_rejected(self):
        self.make_app(version="999.0.0")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version does not match", result.stderr)
        self.assert_no_artifacts()

    def test_wrong_bundle_identifier_is_rejected(self):
        self.make_app(identifier="com.example.synthetic")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("bundle identifier", result.stderr)
        self.assert_no_artifacts()

    def test_unsigned_app_is_rejected(self):
        self.make_app(signed=False)
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature verification failed", result.stderr)
        self.assert_no_artifacts()

    def test_tampered_app_is_rejected(self):
        (self.app / "Contents/Resources/fixture.txt").write_text("tampered", encoding="utf-8")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signature verification failed", result.stderr)
        self.assert_no_artifacts()

    def test_each_missing_signing_setting_fails_before_work(self):
        environment, trace = self.mock_tools()
        for setting in SIGNING_ENV:
            with self.subTest(setting=setting):
                incomplete = environment.copy()
                incomplete.pop(setting)
                result = self.run_script(notarize=True, environment=incomplete)
                self.assertNotEqual(result.returncode, 0)
                if setting == "ASKKEY_NOTARY_PROFILE":
                    self.assertIn("Exactly one of --notary-credential or ASKKEY_NOTARY_PROFILE",
                                  result.stderr)
                else:
                    self.assertIn(f"{setting} is required", result.stderr)
                self.assertFalse(trace.exists())
                self.assert_no_artifacts()

    def test_invalid_arguments_and_missing_app_are_rejected(self):
        for arguments, message in ((["--app"], "requires a path"),
                                   (["--output"], "requires a path"),
                                   (["--notary-credential"], "requires a name"),
                                   (["--unknown"], "Unknown argument"),
                                   (["--app", self.directory / "missing.app"], "App bundle not found")):
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assert_no_artifacts()

    def mock_tools(self):
        """Never invoke a real signing identity, keychain profile or notary service."""
        tools = self.directory / "tools"
        tools.mkdir()
        trace = self.directory / "calls.jsonl"
        command = tools / "mock-tool"
        command.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

name, arguments = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["PACKAGE_TEST_TRACE"], "a") as stream:
    stream.write(json.dumps([name, *arguments]) + "\\n")
failure = os.environ.get("PACKAGE_TEST_FAILURE", "")
if name == "ditto":
    sys.exit(subprocess.call(["/usr/bin/ditto", *arguments]))
if name == "codesign":
    if "-dv" in arguments:
        team = "OTHERTEAM0" if failure == "team" else "FAKETEAM01"
        print("TeamIdentifier=" + team, file=sys.stderr)
    if "--sign" in arguments:
        print(os.environ["ASKKEY_CODESIGN_IDENTITY"], file=sys.stderr)
        sys.exit(1 if failure == "dmg-sign" else 0)
elif name == "hdiutil":
    if failure == "dmg-create":
        sys.exit(1)
    staging = Path(arguments[arguments.index("-srcfolder") + 1])
    assert {path.name for path in staging.iterdir()} == {"Ask Key.app", "Applications"}
    assert (staging / "Applications").is_symlink()
    Path(arguments[-1]).write_bytes(b"synthetic disk image")
elif name == "xcrun":
    profile = os.environ.get("ASKKEY_NOTARY_PROFILE")
    if profile:
        print(profile, file=sys.stderr)
    if arguments[:2] == ["notarytool", "submit"]:
        artifact = Path(arguments[2])
        kind = "app" if artifact.suffix == ".zip" else "dmg"
        if failure == "invalid-json":
            print("{}")
        else:
            status = "Invalid" if failure == kind + "-notary" else "Accepted"
            print(json.dumps({"status": status, "id": "12345678-1234-1234-1234-123456789abc"}))
        sys.exit(1 if failure == "notary-command" else 0)
    elif arguments[0] == "stapler":
        artifact = Path(arguments[2])
        kind = "app" if artifact.suffix == ".app" else "dmg"
        if failure == kind + "-" + arguments[1]:
            sys.exit(1)
        if kind == "dmg" and arguments[1] == "staple":
            with artifact.open("ab") as stream:
                stream.write(b":stapled")
    else:
        sys.exit(1)
elif name == "spctl":
    kind = "app" if "exec" in arguments else "dmg"
    if failure == kind + "-gatekeeper":
        sys.exit(1)
    print(str(arguments[-1]) + ": accepted")
    print("source=" + ("Developer ID" if failure == "app-source" else "Notarized Developer ID"))
elif name == "askkey":
    if not arguments or arguments[0] != "run" or "--" not in arguments:
        sys.exit(1)
    artifact = Path(arguments[arguments.index("--") + 1:][-1])
    kind = "app" if artifact.suffix == ".zip" else "dmg"
    if failure == "invalid-json":
        print("{}")
    else:
        status = "Invalid" if failure == kind + "-notary" else "Accepted"
        print(json.dumps({"status": status, "id": "12345678-1234-1234-1234-123456789abc"}))
    sys.exit(1 if failure == "notary-command" else 0)
else:
    sys.exit(1)
''', encoding="utf-8")
        command.chmod(0o755)
        for name in ("codesign", "ditto", "hdiutil", "xcrun", "spctl", "askkey"):
            (tools / name).symlink_to(command)
        environment = self.environment.copy()
        environment.update({
            "PATH": f"{tools}{os.pathsep}{environment['PATH']}",
            "PACKAGE_TEST_TRACE": str(trace),
            "ASKKEY_CODESIGN_IDENTITY": "synthetic-signing-identity",
            "ASKKEY_APPLE_TEAM_ID": "FAKETEAM01",
            "ASKKEY_NOTARY_PROFILE": "synthetic-notary-profile",
            "ASKKEY_RELEASE_HELPER": str(tools / "askkey"),
            **SYNTHETIC_MAPPINGS,
        })
        return environment, trace

    def assert_settings_not_printed(self, result, environment):
        text = result.stdout + result.stderr
        for setting in SIGNING_ENV:
            if setting in environment:
                self.assertNotIn(environment[setting], text)
        for value in SYNTHETIC_MAPPINGS.values():
            self.assertNotIn(value, text)

    def assert_credential_submit(self, call, suffix):
        self.assertEqual(call[:6], ["askkey", "run", "--wait-for-approval", "--credential",
                                    NOTARY_CREDENTIAL, "--operation-id"])
        operation_id = call[6]
        self.assertTrue(operation_id)
        self.assertEqual(call[7:16], [
            "--caller-name", "AskKey release", "--caller-purpose",
            f"Notarize AskKey {self.version}", "--", "/bin/bash", "-c", NOTARY_SHELL, "bash",
        ])
        self.assertEqual(Path(call[16]).suffix, suffix)
        self.assertEqual(len(call), 17)
        return operation_id

    def credential_environment(self):
        environment, trace = self.mock_tools()
        environment.pop("ASKKEY_NOTARY_PROFILE")
        return environment, trace

    def test_mocked_notarization_checks_both_artifacts_before_checksum(self):
        environment, trace = self.mock_tools()
        result = self.run_script(notarize=True, environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_settings_not_printed(result, environment)
        image = self.output / f"AskKey-{self.version}.dmg"
        self.assertTrue(image.read_bytes().endswith(b":stapled"))
        self.assertIn("Notarized: true", result.stdout)
        self.assert_checksum(image)
        calls = [json.loads(line) for line in trace.read_text().splitlines()]
        submissions = [call for call in calls if call[:3] == ["xcrun", "notarytool", "submit"]]
        self.assertEqual([Path(call[3]).suffix for call in submissions], [".zip", ".dmg"])
        for call in submissions:
            self.assertEqual(call[4:], ["--keychain-profile", environment["ASKKEY_NOTARY_PROFILE"],
                                        "--wait", "--output-format", "json"])
        self.assertEqual([call[2] for call in calls if call[:2] == ["xcrun", "stapler"]],
                         ["staple", "validate", "staple", "validate"])
        signing = [call for call in calls if call[:2] == ["codesign", "--sign"]]
        self.assertEqual(len(signing), 1)
        self.assertIn("--timestamp", signing[0])
        assessments = [call for call in calls if call[0] == "spctl"]
        self.assertEqual(len(assessments), 2)
        self.assertIn("exec", assessments[0])
        self.assertIn("context:primary-signature", assessments[1])
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_credential_mode_builds_askkey_run_invocation(self):
        environment, trace = self.credential_environment()
        result = self.run_script("--notary-credential", NOTARY_CREDENTIAL, notarize=True,
                                 environment=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_settings_not_printed(result, environment)
        image = self.output / f"AskKey-{self.version}.dmg"
        self.assertTrue(image.read_bytes().endswith(b":stapled"))
        self.assertIn("Notarized: true", result.stdout)
        self.assert_checksum(image)
        calls = [json.loads(line) for line in trace.read_text().splitlines()]
        submissions = [call for call in calls if call[0] == "askkey"]
        self.assertEqual(len(submissions), 2)
        operation_ids = [self.assert_credential_submit(call, suffix)
                         for call, suffix in zip(submissions, (".zip", ".dmg"))]
        self.assertEqual(len(set(operation_ids)), 2)
        self.assertFalse(any(call[:3] == ["xcrun", "notarytool", "submit"] for call in calls))
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_notary_modes_conflict_before_work(self):
        environment, trace = self.mock_tools()
        cases = (
            (["--notary-credential", NOTARY_CREDENTIAL], True, environment,
             "Notary credential and ASKKEY_NOTARY_PROFILE modes conflict"),
            (["--notary-credential", NOTARY_CREDENTIAL], False, self.environment,
             "Notary credential and --no-notarize modes conflict"),
            ([], True, {key: value for key, value in environment.items()
                        if key != "ASKKEY_NOTARY_PROFILE"},
             "Exactly one of --notary-credential or ASKKEY_NOTARY_PROFILE is required"),
        )
        for arguments, notarize, env, message in cases:
            with self.subTest(message=message):
                result = self.run_script(*arguments, notarize=notarize, environment=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(trace.exists())
                self.assert_no_artifacts()

    def test_notary_credential_conflicts_with_no_notarize_without_an_app(self):
        result = subprocess.run(
            ["bash", str(SCRIPT), "--notary-credential", "x", "--no-notarize"],
            cwd=self.directory, env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("modes conflict", result.stderr)
        self.assertNotIn("App bundle not found", result.stderr)

    def test_default_output_path_is_not_under_a_symlink(self):
        environment, _ = self.mock_tools()
        default = ROOT / ".build/release-artifacts"
        image = default / f"AskKey-{self.version}-unnotarized.dmg"
        checksum = default / f"{image.name}.sha256"
        existed = default.exists()
        for path in (image, checksum):
            if path.exists() or path.is_symlink():
                path.unlink()

        def cleanup():
            for path in (image, checksum):
                if path.is_file() or path.is_symlink():
                    path.unlink()
            if not existed and default.is_dir() and not any(default.iterdir()):
                default.rmdir()

        self.addCleanup(cleanup)
        result = self.run_script(environment=environment, output=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(image.is_file())
        self.assertFalse(default.is_symlink())
        self.assertNotEqual(default, ROOT / ".build/release")
        swiftpm = ROOT / ".build/release"
        if swiftpm.exists() or swiftpm.is_symlink():
            resolved_default = default.resolve()
            resolved_release = swiftpm.resolve()
            self.assertNotEqual(resolved_default, resolved_release)
            try:
                resolved_default.relative_to(resolved_release)
            except ValueError:
                pass
            else:
                self.fail("default output resolved under SwiftPM .build/release")
        self.assertIn(f"DMG: {image.resolve()}", result.stdout)

    def test_signing_team_mismatch_is_rejected_before_staging(self):
        environment, trace = self.mock_tools()
        environment["PACKAGE_TEST_FAILURE"] = "team"
        result = self.run_script(notarize=True, environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("signing team mismatch", result.stderr)
        self.assert_settings_not_printed(result, environment)
        self.assertEqual([json.loads(line)[0] for line in trace.read_text().splitlines()],
                         ["codesign", "codesign"])
        self.assert_no_artifacts()

    def test_notarization_and_gate_failures_publish_nothing_and_clean_staging(self):
        environment, _ = self.mock_tools()
        failures = ("app-notary", "dmg-notary", "invalid-json", "notary-command",
                    "app-staple", "app-validate", "app-gatekeeper", "app-source",
                    "dmg-create", "dmg-sign", "dmg-staple", "dmg-validate", "dmg-gatekeeper")
        for failure in failures:
            with self.subTest(failure=failure):
                environment["PACKAGE_TEST_FAILURE"] = failure
                result = self.run_script(notarize=True, environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assert_settings_not_printed(result, environment)
                if failure in ("app-notary", "dmg-notary", "notary-command"):
                    self.assertIn(f"xcrun notarytool log {SUBMISSION_ID} --keychain-profile ...",
                                  result.stderr)
                self.assert_no_artifacts()

    def test_credential_mode_failures_publish_nothing_and_clean_staging(self):
        environment, _ = self.credential_environment()
        for failure in ("app-notary", "dmg-notary", "invalid-json", "notary-command"):
            with self.subTest(failure=failure):
                environment["PACKAGE_TEST_FAILURE"] = failure
                result = self.run_script("--notary-credential", NOTARY_CREDENTIAL, notarize=True,
                                         environment=environment)
                self.assertNotEqual(result.returncode, 0)
                self.assert_settings_not_printed(result, environment)
                if failure in ("app-notary", "dmg-notary", "notary-command"):
                    self.assertIn(f"xcrun notarytool log {SUBMISSION_ID} --key ... --key-id ... --issuer ...",
                                  result.stderr)
                self.assert_no_artifacts()

    def test_existing_artifact_is_not_overwritten(self):
        environment, _ = self.mock_tools()
        self.output.mkdir()
        image = self.output / f"AskKey-{self.version}-unnotarized.dmg"
        image.write_bytes(b"existing artifact")
        result = self.run_script(environment=environment)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Output artifacts already exist", result.stderr)
        self.assertEqual(image.read_bytes(), b"existing artifact")
        self.assertEqual(list(self.output.iterdir()), [image])
        self.assertEqual(list(self.scratch.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
