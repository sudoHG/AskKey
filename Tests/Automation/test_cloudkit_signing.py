"""Check the CloudKit profile checks with synthetic decoded profiles, and package-release.sh's check."""

from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/cloudkit-signing.py"
PACKAGE = ROOT / "scripts/package-release.sh"
TOOL = ROOT / "Tests/Automation/Fixtures/cloudkit-signing-tool.py"
SPEC = importlib.util.spec_from_file_location("cloudkit_signing", HELPER)
signing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(signing)

TEAM = "FAKETEAM01"
OTHER_TEAM = "OTHERTEAM2"
BUNDLE_ID = "com.sudohg.askkey.app"
CONTAINER = "iCloud.com.sudohg.askkey"
CERTIFICATE = b"synthetic leaf certificate for AskKey tests"
CERTIFICATE_SHA1 = hashlib.sha1(CERTIFICATE).hexdigest().upper()
IDENTITY_NAME = "Developer ID Application: Synthetic Tester (FAKETEAM01)"
ENTITLEMENTS = {
    "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
    "com.apple.developer.team-identifier": TEAM,
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-identifiers": [CONTAINER],
    "com.apple.developer.icloud-container-environment": "Production",
    "com.apple.developer.aps-environment": "production",
}
STUB_TOOLS = ("swift", "xcodebuild", "codesign", "security", "otool", "install_name_tool", "df", "git")


def now():
    return datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


def synthetic_profile(expires=None, **changes):
    """A decoded Developer ID profile, as `security cms -D` prints one, with synthetic values."""
    profile = {
        "AppIDName": "Synthetic",
        "Name": "Synthetic Developer ID profile",
        "Platform": ["OSX"],
        "ProvisionsAllDevices": True,
        "TeamIdentifier": [TEAM],
        "CreationDate": now() - timedelta(days=1),
        "ExpirationDate": expires or now() + timedelta(days=365),
        "DeveloperCertificates": [CERTIFICATE],
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.icloud-services": ["CloudKit", "CloudKit-Anonymous"],
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-container-environment": ["Production"],
            "com.apple.developer.aps-environment": "production",
        },
    }
    for key, value in changes.items():
        if key in profile["Entitlements"]:
            target = profile["Entitlements"]
        else:
            target = profile
        if value is None:
            target.pop(key, None)
        else:
            target[key] = value
    return profile


def install_stubs(directory, names=STUB_TOOLS):
    tools = Path(directory) / "tools"
    tools.mkdir()
    command = tools / "cloudkit-signing-tool"
    shutil.copyfile(TOOL, command)
    command.chmod(0o755)
    for name in names:
        (tools / name).symlink_to(command)
    return tools


def stub_environment(directory, tools, trace, **extra):
    state = Path(directory) / "tool-state"
    state.mkdir(exist_ok=True)
    certificate = Path(directory) / "leaf.der"
    certificate.write_bytes(CERTIFICATE)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("ASKKEY_")}
    environment.update({
        "PATH": f"{tools}{os.pathsep}{environment['PATH']}",
        "CLOUDKIT_TEST_TRACE": str(trace),
        "CLOUDKIT_TEST_STATE": str(state),
        "CLOUDKIT_TEST_CERTIFICATE": str(certificate),
        "CLOUDKIT_TEST_IDENTITIES": json.dumps([[CERTIFICATE_SHA1, IDENTITY_NAME]]),
    })
    environment.update(extra)
    return environment


def read_trace(trace):
    return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []


def package_release_tests():
    spec = importlib.util.spec_from_file_location("package_release_mounting",
                                                  ROOT / "Tests/Automation/test_package_release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProfileCheckTests(unittest.TestCase):
    def problems(self, profile, certificate=CERTIFICATE_SHA1):
        return signing.profile_problems(profile, TEAM, certificate)

    def assertRefused(self, profile, expected, certificate=CERTIFICATE_SHA1):
        problems = self.problems(profile, certificate)
        self.assertTrue(any(expected in problem for problem in problems), problems)
        self.assertFalse([problem for problem in problems if TEAM in problem], "messages must not name the team")

    def test_valid_profile_has_no_problems(self):
        self.assertEqual(self.problems(synthetic_profile()), [])
        self.assertEqual(self.problems(synthetic_profile(), CERTIFICATE_SHA1.lower()), [])

    def test_wildcard_services_and_a_single_environment_string_are_accepted(self):
        profile = synthetic_profile(**{"com.apple.developer.icloud-services": "*",
                                       "com.apple.developer.icloud-container-environment": "Production"})
        self.assertEqual(self.problems(profile), [])

    def test_wrong_app_id_is_refused(self):
        for app_id in (f"{TEAM}.com.sudohg.askkey.app.dev", f"{TEAM}.*", f"{OTHER_TEAM}.{BUNDLE_ID}", BUNDLE_ID):
            with self.subTest(app_id=app_id):
                self.assertRefused(synthetic_profile(**{"com.apple.application-identifier": app_id}), "App ID")

    def test_wrong_team_is_refused(self):
        message = "its team is not the one in ASKKEY_APPLE_TEAM_ID"
        self.assertRefused(synthetic_profile(TeamIdentifier=[OTHER_TEAM]), message)
        self.assertRefused(synthetic_profile(**{"com.apple.developer.team-identifier": OTHER_TEAM}), message)

    def test_wrong_profile_type_is_refused(self):
        development = synthetic_profile(ProvisionsAllDevices=None, ProvisionedDevices=["00008103-SYNTHETIC"])
        app_store = synthetic_profile(ProvisionsAllDevices=None)
        ad_hoc_all = synthetic_profile(ProvisionedDevices=["00008103-SYNTHETIC"])
        for profile in (development, app_store, ad_hoc_all):
            self.assertRefused(profile, "not a Developer ID profile")
        self.assertRefused(synthetic_profile(Platform=["iOS"]), "not a macOS profile")
        self.assertRefused(synthetic_profile(Platform=None), "not a macOS profile")

    def test_wrong_environment_is_refused(self):
        self.assertRefused(synthetic_profile(**{"com.apple.developer.aps-environment": "development"}),
                           "production push")
        self.assertRefused(synthetic_profile(**{"com.apple.developer.icloud-container-environment": ["Development"]}),
                           "Production environment")

    def test_expired_profile_is_refused(self):
        self.assertRefused(synthetic_profile(expires=now() - timedelta(minutes=1)), "expired on")
        self.assertRefused(synthetic_profile(ExpirationDate=None), "no expiration date")

    def test_each_missing_entitlement_is_refused(self):
        cases = {
            "com.apple.application-identifier": "App ID",
            "com.apple.developer.team-identifier": "its team is not the one in ASKKEY_APPLE_TEAM_ID",
            "com.apple.developer.icloud-services": "CloudKit service",
            "com.apple.developer.icloud-container-identifiers": f"container {CONTAINER}",
            "com.apple.developer.icloud-container-environment": "Production environment",
            "com.apple.developer.aps-environment": "production push",
        }
        for key, expected in cases.items():
            with self.subTest(key=key):
                self.assertRefused(synthetic_profile(**{key: None}), expected)
        self.assertRefused(synthetic_profile(**{"com.apple.developer.icloud-services": ["CloudDocuments"]}),
                           "CloudKit service")
        self.assertRefused(synthetic_profile(**{"com.apple.developer.icloud-container-identifiers":
                                                ["iCloud.com.sudohg.askkey.probe"]}), "container")
        self.assertRefused(synthetic_profile(Entitlements=None), "CloudKit service")

    def test_certificate_the_profile_does_not_list_is_refused(self):
        other = hashlib.sha1(b"another synthetic certificate").hexdigest().upper()
        self.assertRefused(synthetic_profile(), "does not list the signing certificate", other)
        self.assertRefused(synthetic_profile(), "does not list the signing certificate", None)
        self.assertRefused(synthetic_profile(DeveloperCertificates=None), "does not list the signing certificate")

    def test_signing_entitlements_are_exactly_the_listed_six(self):
        self.assertEqual(signing.expected_entitlements(TEAM), ENTITLEMENTS)

    def test_identity_resolution_follows_codesign(self):
        other = "0" * 40
        listing = (f'  1) {CERTIFICATE_SHA1} "{IDENTITY_NAME}"\n'
                   f'  2) {other} "Developer ID Application: Synthetic Tester Two (OTHERTEAM2)"\n'
                   f'  3) {CERTIFICATE_SHA1} "{IDENTITY_NAME}"\n     3 valid identities found\n')
        resolve = signing.resolve_identity
        self.assertEqual(resolve(CERTIFICATE_SHA1.lower(), listing), [CERTIFICATE_SHA1])
        self.assertEqual(resolve(IDENTITY_NAME, listing), [CERTIFICATE_SHA1])
        self.assertEqual(resolve("Synthetic Tester (", listing), [CERTIFICATE_SHA1])
        self.assertEqual(resolve("Developer ID Application", listing), sorted([CERTIFICATE_SHA1, other]))
        self.assertEqual(resolve("1" * 40, listing), [])
        self.assertEqual(resolve("Apple Development", listing), [])


class PrepareCommandTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-cloudkit-prepare-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.trace = self.directory / "calls.jsonl"
        self.environment = stub_environment(self.directory, install_stubs(self.directory, ["security"]),
                                            self.trace)
        self.output = self.directory / "work"

    def prepare(self, profile=None, data=None, identity=IDENTITY_NAME, team=TEAM, **environment):
        source = self.directory / "Synthetic.provisionprofile"
        source.write_bytes(data if data is not None else plistlib.dumps(profile or synthetic_profile()))
        return subprocess.run(
            ["python3", str(HELPER), "prepare", "--profile", str(source), "--identity", identity,
             "--team", team, "--output", str(self.output)],
            env=dict(self.environment, **environment), text=True, capture_output=True, timeout=60)

    def assertFailed(self, result, message):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.output / "signing-certificate").exists())
        for secret in (TEAM, IDENTITY_NAME, CERTIFICATE_SHA1):
            self.assertNotIn(secret, result.stdout + result.stderr)

    def test_valid_profile_is_snapshotted_with_the_signing_certificate(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        source = self.directory / "Synthetic.provisionprofile"
        self.assertEqual((self.output / "embedded.provisionprofile").read_bytes(), source.read_bytes())
        self.assertEqual((self.output / "signing-certificate").read_text(), CERTIFICATE_SHA1 + "\n")
        self.assertIn(f"Developer ID for {BUNDLE_ID} with {CONTAINER}", result.stdout)
        for secret in (TEAM, IDENTITY_NAME, CERTIFICATE_SHA1):
            self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertEqual([call[:3] for call in read_trace(self.trace)],
                         [["security", "cms", "-D"], ["security", "find-identity", "-v"]])

    def test_profile_problems_are_listed(self):
        result = self.prepare(synthetic_profile(expires=now() - timedelta(days=2),
                                                **{"com.apple.developer.aps-environment": "development"}))
        self.assertFailed(result, "The provisioning profile cannot sign this build")
        self.assertIn("expired on", result.stderr)
        self.assertIn("production push", result.stderr)

    def test_undecodable_profile_and_bad_team_are_refused(self):
        self.assertFailed(self.prepare(data=b"not a profile"), "Cannot decode the provisioning profile")
        self.assertFailed(self.prepare(team="faketeam01"), "10-character Apple team ID")

    def test_identity_must_match_exactly_one_certificate(self):
        self.assertFailed(self.prepare(identity="Apple Development"), "exactly one valid code signing identity")
        two = json.dumps([[CERTIFICATE_SHA1, IDENTITY_NAME],
                          ["0" * 40, "Developer ID Application: Synthetic Tester Two (OTHERTEAM2)"]])
        self.assertFailed(self.prepare(identity="Developer ID Application", CLOUDKIT_TEST_IDENTITIES=two),
                          "exactly one valid code signing identity")

    def test_missing_profile_file_is_refused(self):
        result = subprocess.run(
            ["python3", str(HELPER), "prepare", "--profile", str(self.directory / "missing"),
             "--identity", IDENTITY_NAME, "--team", TEAM, "--output", str(self.output)],
            env=self.environment, text=True, capture_output=True, timeout=60)
        self.assertFailed(result, "must name a provisioning profile file")


class PackageReleaseProfileTests(unittest.TestCase):
    """package-release.sh checks an embedded profile before notarizing; real ad hoc signatures."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-cloudkit-package-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.scratch = self.directory / "scratch"
        self.scratch.mkdir()
        self.output = self.directory / "output"
        self.trace = self.directory / "calls.jsonl"
        self.version = subprocess.check_output(["bash", str(ROOT / "scripts/product-version.sh")],
                                               text=True).strip()
        tools = install_stubs(self.directory, ["security", "codesign"])
        self.environment = stub_environment(self.directory, tools, self.trace, ASKKEY_APPLE_TEAM_ID=TEAM,
                                            CLOUDKIT_TEST_DELEGATE_CODESIGN="1", TMPDIR=str(self.scratch))
        self.app = self.directory / "Fixture.app"

    def make_app(self, profile=None, entitlements=ENTITLEMENTS):
        contents = self.app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copyfile("/usr/bin/true", contents / "MacOS/Fixture")
        (contents / "MacOS/Fixture").chmod(0o755)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Fixture", "CFBundleIdentifier": BUNDLE_ID,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": self.version,
            "CFBundleVersion": self.version, "AskKeyCloudKitContainer": CONTAINER,
        }))
        (contents / "embedded.provisionprofile").write_bytes(plistlib.dumps(profile or synthetic_profile()))
        entitlements_file = self.directory / "fixture.entitlements"
        entitlements_file.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlements_file),
                        str(self.app)], check=True, capture_output=True)

    def package(self, *arguments, environment=None):
        return subprocess.run(["bash", str(PACKAGE), "--app", str(self.app), "--output", str(self.output),
                               *arguments], env=environment or self.environment, cwd=self.directory,
                              text=True, capture_output=True, timeout=120)

    def assertRefused(self, result, message="The embedded provisioning profile or the signed entitlements"):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertNotIn(TEAM, result.stdout + result.stderr)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_valid_profile_is_checked_and_kept_in_the_dmg(self):
        self.make_app()
        result = self.package("--no-notarize")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("embedded provisioning profile is valid and sealed", result.stdout)
        calls = read_trace(self.trace)
        self.assertIn(["security", "cms", "-D", "-i"], [call[:4] for call in calls])
        image = self.output / f"AskKey-{self.version}-unnotarized.dmg"
        mountpoint = self.directory / "mounted"
        mountpoint.mkdir()
        # Mount the way test_package_release does, with its diskutil-then-hdiutil fallbacks.
        packaging = package_release_tests().PackageReleaseTests
        packaging.attach_image(self, image, mountpoint)
        try:
            kept = mountpoint / "Ask Key.app/Contents/embedded.provisionprofile"
            self.assertEqual(kept.read_bytes(), (self.app / "Contents/embedded.provisionprofile").read_bytes())
        finally:
            packaging.eject_image(self, mountpoint)

    def test_expired_or_mismatched_profile_is_refused(self):
        cases = (
            (synthetic_profile(expires=now() - timedelta(days=1)), ENTITLEMENTS),
            (synthetic_profile(TeamIdentifier=[OTHER_TEAM]), ENTITLEMENTS),
            (synthetic_profile(DeveloperCertificates=[b"another synthetic certificate"]), ENTITLEMENTS),
            (synthetic_profile(), dict(ENTITLEMENTS, **{"com.apple.developer.aps-environment": "development"})),
            (synthetic_profile(), {key: value for key, value in ENTITLEMENTS.items()
                                   if key != "com.apple.developer.aps-environment"}),
        )
        for index, (profile, entitlements) in enumerate(cases):
            with self.subTest(case=index):
                shutil.rmtree(self.app, ignore_errors=True)
                self.make_app(profile, entitlements)
                self.assertRefused(self.package("--no-notarize"))

    def test_profile_changed_after_signing_is_refused(self):
        self.make_app()
        profile = self.app / "Contents/embedded.provisionprofile"
        profile.write_bytes(plistlib.dumps(synthetic_profile(expires=now() + timedelta(days=9000))))
        self.assertRefused(self.package("--no-notarize"), "signature verification failed")

    def test_team_is_required_to_check_a_profile(self):
        self.make_app()
        environment = {key: value for key, value in self.environment.items() if key != "ASKKEY_APPLE_TEAM_ID"}
        self.assertRefused(self.package("--no-notarize", environment=environment),
                           "ASKKEY_APPLE_TEAM_ID is required to check the embedded provisioning profile")

    def test_invalid_profile_stops_before_any_notarization_request(self):
        self.make_app(synthetic_profile(expires=now() - timedelta(days=1)))
        tools = self.directory / "package-tools"
        tools.mkdir()
        mock = tools / "package-release-tool"
        shutil.copyfile(ROOT / "Tests/Automation/Fixtures/package-release-tool.py", mock)
        mock.chmod(0o755)
        for name in ("codesign", "ditto", "hdiutil", "xcrun", "spctl", "askkey"):
            (tools / name).symlink_to(mock)
        notes = self.directory / "notes.md"
        notes.write_text("<!-- lang: en -->\nSynthetic.\n<!-- lang: zh-Hans -->\nSynthetic zh.\n", encoding="utf-8")
        environment = dict(self.environment, PACKAGE_TEST_TRACE=str(self.trace), ASKKEY_RELEASE_HELPER=str(tools / "askkey"),
                           ASKKEY_CODESIGN_IDENTITY="synthetic-signing-identity",
                           ASKKEY_NOTARY_PROFILE="synthetic-notary-profile")
        stub_tools, rest = environment["PATH"].split(os.pathsep, 1)
        environment["PATH"] = os.pathsep.join([stub_tools, str(tools), rest])
        result = self.package("--sparkle-key-credential", "synthetic-sparkle-key", "--release-notes", str(notes),
                              environment=environment)
        self.assertRefused(result)
        self.assertNotIn("synthetic-signing-identity", result.stdout + result.stderr)
        calls = read_trace(self.trace)
        self.assertIn(["security", "cms", "-D", "-i"], [call[:4] for call in calls])
        self.assertFalse([call for call in calls if call[0] in ("xcrun", "spctl", "askkey", "hdiutil")], calls)

    def test_check_runs_after_staging_and_before_notarizing(self):
        source = PACKAGE.read_text(encoding="utf-8")
        check = source.index('scripts/cloudkit-signing.py" check-app --app "$STAGED_APP"')
        self.assertLess(source.index('ditto "$APP" "$STAGED_APP"'), check)
        self.assertLess(check, source.index('notarize "$APP_ZIP"'))
        self.assertLess(check, source.index('hdiutil create'))


if __name__ == "__main__":
    unittest.main()
