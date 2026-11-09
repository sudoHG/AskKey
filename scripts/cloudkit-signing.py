#!/usr/bin/env python3
"""Check the Developer ID provisioning profile and the CloudKit signing of a Local build.

build-app.sh runs `prepare` before building, `entitlements` right before it
signs the App and `verify` after signing; package-release.sh runs `check-app`
before notarizing (#286, ADR 0013 in #291). The team comes from
ASKKEY_APPLE_TEAM_ID at build time. Messages name no team ID, signing identity
or certificate.
"""

import argparse
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

BUNDLE_ID = "com.sudohg.askkey.app"
CONTAINER = "iCloud.com.sudohg.askkey"
INFO_PLIST_KEY = "AskKeyCloudKitContainer"
PROFILE_NAME = "embedded.provisionprofile"
ENTITLEMENTS_NAME = "AskKeyApp.entitlements"
CERTIFICATE_NAME = "signing-certificate"
TEAM_PATTERN = re.compile(r"[A-Z0-9]{10}")
SHA1_PATTERN = re.compile(r"[0-9A-Fa-f]{40}")
# `security find-identity -v` lists valid identities as `  1) <SHA-1> "<common name>"`.
IDENTITY_LINE = re.compile(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"(.*)"\s*$')


class SigningError(Exception):
    def __init__(self, message, problems=()):
        super().__init__(message)
        self.problems = list(problems)


def expected_entitlements(team):
    """The entitlements the App is signed with, as listed in #281 and ADR 0013."""
    return {
        "com.apple.application-identifier": f"{team}.{BUNDLE_ID}",
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.developer.aps-environment": "production",
    }


def check_team(team):
    if not TEAM_PATTERN.fullmatch(team or ""):
        raise SigningError("ASKKEY_APPLE_TEAM_ID must be a 10-character Apple team ID.")


def run(command):
    """Return a tool's standard output, or None when it fails; its diagnostics are never shown."""
    try:
        result = subprocess.run(command, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def decode_profile(path):
    output = run(["security", "cms", "-D", "-i", str(path)])
    try:
        profile = plistlib.loads(output) if output else None
    except Exception:
        profile = None
    if not isinstance(profile, dict):
        raise SigningError("Cannot decode the provisioning profile.")
    return profile


def certificate_sha1(der):
    return hashlib.sha1(der).hexdigest().upper()


def utc(value):
    """plistlib returns naive UTC datetimes; compare everything in naive UTC."""
    if value.tzinfo is not None:
        value = value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def profile_problems(profile, team, certificate, now=None):
    """Every reason the decoded profile cannot sign the CloudKit build with this certificate."""
    now = utc(now or datetime.now(timezone.utc))
    problems = []
    platforms = profile.get("Platform")
    if not isinstance(platforms, list) or "OSX" not in platforms:
        problems.append("it is not a macOS profile")
    if profile.get("ProvisionsAllDevices") is not True or "ProvisionedDevices" in profile:
        problems.append("it is not a Developer ID profile (development, ad hoc and App Store profiles are refused)")
    granted = profile.get("Entitlements")
    if not isinstance(granted, dict):
        granted = {}
    if granted.get("com.apple.application-identifier") != f"{team}.{BUNDLE_ID}":
        problems.append(f"its App ID is not {BUNDLE_ID} in the team from ASKKEY_APPLE_TEAM_ID")
    if profile.get("TeamIdentifier") != [team] or granted.get("com.apple.developer.team-identifier") != team:
        problems.append("its team is not the one in ASKKEY_APPLE_TEAM_ID")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        problems.append("it has no expiration date")
    elif utc(expiration) <= now:
        problems.append(f"it expired on {utc(expiration):%Y-%m-%d}")
    listed = {certificate_sha1(der) for der in profile.get("DeveloperCertificates") or [] if isinstance(der, bytes)}
    if certificate is None or certificate.upper() not in listed:
        problems.append("it does not list the signing certificate")
    services = granted.get("com.apple.developer.icloud-services")
    if services != "*" and not (isinstance(services, list) and "CloudKit" in services):
        problems.append("it does not grant the CloudKit service")
    containers = granted.get("com.apple.developer.icloud-container-identifiers")
    if not isinstance(containers, list) or CONTAINER not in containers:
        problems.append(f"it does not grant the container {CONTAINER}")
    environments = granted.get("com.apple.developer.icloud-container-environment")
    if isinstance(environments, str):
        environments = [environments]
    if not isinstance(environments, list) or "Production" not in environments:
        problems.append("it does not grant the CloudKit Production environment")
    if granted.get("com.apple.developer.aps-environment") != "production":
        problems.append("it does not grant production push notifications")
    return problems


def resolve_identity(identity, listing):
    """The certificate hashes codesign would pick for an identity (see `man codesign`)."""
    identities = {}
    for line in listing.splitlines():
        match = IDENTITY_LINE.match(line)
        if match:
            identities.setdefault(match.group(1), match.group(2))
    if SHA1_PATTERN.fullmatch(identity):
        return [identity.upper()] if identity.upper() in identities else []
    exact = sorted(sha for sha, name in identities.items() if name == identity)
    return exact or sorted(sha for sha, name in identities.items() if identity in name)


def signing_certificate(identity):
    listing = run(["security", "find-identity", "-v", "-p", "codesigning"])
    if listing is None:
        raise SigningError("Cannot list the code signing identities in the keychain.")
    matches = resolve_identity(identity, listing.decode("utf-8", "replace"))
    if len(matches) != 1:
        raise SigningError("ASKKEY_CODESIGN_IDENTITY must match exactly one valid code signing identity.")
    return matches[0]


def signed_entitlements(app):
    output = run(["codesign", "-d", "--entitlements", "-", "--xml", str(app)])
    if output is None:
        return None
    try:
        return plistlib.loads(output) if output.strip() else {}
    except Exception:
        return None


def leaf_certificate(app):
    with tempfile.TemporaryDirectory(prefix="askkey-cloudkit-certificates-") as directory:
        prefix = Path(directory) / "certificate"
        if run(["codesign", "-d", f"--extract-certificates={prefix}", str(app)]) is None:
            return None
        leaf = Path(f"{prefix}0")
        return certificate_sha1(leaf.read_bytes()) if leaf.is_file() else None


def differing_keys(actual, expected):
    if not isinstance(actual, dict):
        return ["(unreadable)"]
    return sorted(key for key in set(actual) | set(expected) if actual.get(key) != expected.get(key))


def app_problems(app, team):
    """Check a signed App's Info.plist key, embedded profile, certificate and entitlements.

    Returns the problems, the embedded profile's bytes and the leaf certificate's SHA-1.
    """
    problems = []
    contents = app / "Contents"
    try:
        info = plistlib.loads((contents / "Info.plist").read_bytes())
    except Exception:
        info = {}
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        problems.append(f"the App's bundle identifier is not {BUNDLE_ID}")
    if info.get(INFO_PLIST_KEY) != CONTAINER:
        problems.append(f"the App's Info.plist does not declare {INFO_PLIST_KEY} = {CONTAINER}")
    profile_path = contents / PROFILE_NAME
    if profile_path.is_symlink() or not profile_path.is_file():
        return problems + [f"the App has no regular Contents/{PROFILE_NAME}"], None, None
    profile_bytes = profile_path.read_bytes()
    certificate = leaf_certificate(app)
    if certificate is None:
        problems.append("the App's signature has no signing certificate")
    try:
        profile = decode_profile(profile_path)
    except SigningError:
        problems.append("the embedded provisioning profile cannot be decoded")
    else:
        problems += [f"the embedded provisioning profile: {problem}"
                     for problem in profile_problems(profile, team, certificate)]
    keys = differing_keys(signed_entitlements(app), expected_entitlements(team))
    if keys:
        problems.append("the signed entitlements differ from the CloudKit entitlements in: " + ", ".join(keys))
    try:
        seal = plistlib.loads((contents / "_CodeSignature/CodeResources").read_bytes())
        sealed = seal["files2"][PROFILE_NAME]["hash2"]
    except Exception:
        sealed = None
    if sealed != hashlib.sha256(profile_bytes).digest():
        problems.append("the embedded provisioning profile is not the one sealed by the App's signature")
    return problems, profile_bytes, certificate


def prepare(arguments):
    check_team(arguments.team)
    source = Path(arguments.profile)
    if not source.is_file():
        raise SigningError("ASKKEY_PROVISIONING_PROFILE must name a provisioning profile file.")
    output = Path(arguments.output)
    output.mkdir(parents=True, exist_ok=True)
    # Check and later embed the same bytes, even if the source file changes during the build.
    snapshot = output / PROFILE_NAME
    shutil.copyfile(source, snapshot)
    profile = decode_profile(snapshot)
    certificate = signing_certificate(arguments.identity)
    problems = profile_problems(profile, arguments.team, certificate)
    if problems:
        raise SigningError("The provisioning profile cannot sign this build:", problems)
    (output / CERTIFICATE_NAME).write_text(certificate + "\n", encoding="ascii")
    print(f"Provisioning profile: Developer ID for {BUNDLE_ID} with {CONTAINER}, CloudKit and production push; "
          f"expires {utc(profile['ExpirationDate']):%Y-%m-%d}.")


def write_entitlements(arguments):
    check_team(arguments.team)
    with open(arguments.output, "wb") as stream:
        plistlib.dump(expected_entitlements(arguments.team), stream)


def verify(arguments):
    check_team(arguments.team)
    work = Path(arguments.work)
    problems, profile_bytes, certificate = app_problems(Path(arguments.app), arguments.team)
    if profile_bytes is not None and profile_bytes != (work / PROFILE_NAME).read_bytes():
        problems.append("the embedded provisioning profile is not the one that was checked")
    if certificate is not None and certificate != (work / CERTIFICATE_NAME).read_text(encoding="ascii").strip():
        problems.append("the App was not signed with the certificate that was checked")
    try:
        intended = plistlib.loads((work / ENTITLEMENTS_NAME).read_bytes())
    except Exception:
        intended = None
    if intended != expected_entitlements(arguments.team):
        problems.append("the generated entitlements file is not the CloudKit entitlements")
    if problems:
        raise SigningError("The signed App does not match the intended CloudKit signing:", problems)
    print("Read back: the signed entitlements and the embedded provisioning profile are as intended.")


def check_app(arguments):
    check_team(arguments.team)
    problems, _, _ = app_problems(Path(arguments.app), arguments.team)
    if problems:
        raise SigningError("The App's CloudKit signing is not valid:", problems)
    print("The embedded provisioning profile is valid and sealed, and the signed entitlements are as intended.")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("prepare", help="check the profile and the signing identity before building")
    command.add_argument("--profile", required=True)
    command.add_argument("--identity", required=True)
    command.add_argument("--team", required=True)
    command.add_argument("--output", required=True)
    command.set_defaults(handler=prepare)
    command = commands.add_parser("entitlements", help="write the CloudKit signing entitlements")
    command.add_argument("--team", required=True)
    command.add_argument("--output", required=True)
    command.set_defaults(handler=write_entitlements)
    command = commands.add_parser("verify", help="read back a freshly signed App")
    command.add_argument("--app", required=True)
    command.add_argument("--team", required=True)
    command.add_argument("--work", required=True)
    command.set_defaults(handler=verify)
    command = commands.add_parser("check-app", help="check a signed App before notarizing")
    command.add_argument("--app", required=True)
    command.add_argument("--team", required=True)
    command.set_defaults(handler=check_app)
    arguments = parser.parse_args(argv)
    try:
        arguments.handler(arguments)
    except SigningError as error:
        print(f"Error: {error}", file=sys.stderr)
        for problem in error.problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    except OSError as error:
        print(f"Error: cannot read or write {error.filename}: {error.strerror}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
