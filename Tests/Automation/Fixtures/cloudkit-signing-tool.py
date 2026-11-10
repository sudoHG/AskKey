#!/usr/bin/env python3
"""Synthetic build and signing tools for the CloudKit signing tests.

Installed under the names of the tools build-app.sh and cloudkit-signing.py
call. It never reads the keychain or signs anything: `security` decodes plain
property-list "profiles" and lists synthetic identities, and `codesign` records
what it was asked to sign. With CLOUDKIT_TEST_DELEGATE_CODESIGN=1 only the leaf
certificate is synthetic: entitlements come from the real ad hoc signature, and
other codesign calls go to the next codesign on PATH.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys

name, arguments = Path(sys.argv[0]).name, sys.argv[1:]
here = Path(sys.argv[0]).parent.resolve()
failure = os.environ.get("CLOUDKIT_TEST_FAILURE", "")
with open(os.environ["CLOUDKIT_TEST_TRACE"], "a", encoding="utf-8") as stream:
    stream.write(json.dumps([name, *arguments]) + "\n")


def state(*parts):
    return Path(os.environ["CLOUDKIT_TEST_STATE"], *parts)


def stored_entitlements(target):
    key = hashlib.sha256(str(Path(target).resolve()).encode()).hexdigest()
    return state("entitlements", key)


def next_codesign():
    for directory in os.environ["PATH"].split(os.pathsep):
        candidate = Path(directory, "codesign")
        if directory and Path(directory).resolve() != here and os.access(candidate, os.X_OK):
            return str(candidate)
    sys.exit("no codesign after the stub on PATH")


def sign(target, entitlements):
    app = Path.cwd() / ".build/AskKeyApp.app/Contents"
    info = plistlib.loads((app / "Info.plist").read_bytes()) if (app / "Info.plist").is_file() else {}
    with state("signing.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps({"target": target, "entitlements": entitlements is not None,
                                 "profile": (app / "embedded.provisionprofile").is_file(),
                                 "container": info.get("CloudKitContainerIdentifier")}) + "\n")
    record = stored_entitlements(target)
    record.parent.mkdir(parents=True, exist_ok=True)
    if entitlements is None:
        record.unlink(missing_ok=True)
    else:
        values = plistlib.loads(Path(entitlements).read_bytes())
        if failure == "signed-entitlements":
            values["com.apple.developer.aps-environment"] = "development"
        record.write_bytes(plistlib.dumps(values))
    if not target.endswith(".app"):
        return
    profile = Path(target, "Contents/embedded.provisionprofile")
    if failure == "embedded-profile" and profile.is_file():
        profile.write_bytes(profile.read_bytes() + b"\n")
    files = {}
    if profile.is_file():
        files["embedded.provisionprofile"] = {"hash2": hashlib.sha256(profile.read_bytes()).digest()}
    seal = Path(target, "Contents/_CodeSignature/CodeResources")
    seal.parent.mkdir(exist_ok=True)
    seal.write_bytes(plistlib.dumps({"files": {}, "files2": files}))
    if failure == "unsealed" and profile.is_file():
        profile.write_bytes(profile.read_bytes() + b"\n")


if name == "security":
    if arguments[:3] == ["cms", "-D", "-i"]:
        data = Path(arguments[3]).read_bytes()
        try:
            plistlib.loads(data)
        except Exception:
            sys.exit(1)
        sys.stdout.buffer.write(data)
    elif arguments[:1] == ["find-identity"]:
        identities = json.loads(os.environ.get("CLOUDKIT_TEST_IDENTITIES", "[]"))
        for number, (sha, common_name) in enumerate(identities, 1):
            print(f'  {number}) {sha} "{common_name}"')
        print(f"     {len(identities)} valid identities found")
    else:
        sys.exit(1)
elif name == "codesign":
    extract = [argument for argument in arguments if argument.startswith("--extract-certificates=")]
    displays_entitlements = "-d" in arguments and "--entitlements" in arguments
    if extract:
        leaf = Path(os.environ["CLOUDKIT_TEST_CERTIFICATE"]).read_bytes()
        Path(extract[0].split("=", 1)[1] + "0").write_bytes(
            b"another synthetic certificate" if failure == "certificate" else leaf)
    elif os.environ.get("CLOUDKIT_TEST_DELEGATE_CODESIGN") == "1":
        tool = "/usr/bin/codesign" if displays_entitlements else next_codesign()
        os.execv(tool, [tool, *arguments])
    elif displays_entitlements:
        record = stored_entitlements(arguments[-1])
        if record.is_file():
            sys.stdout.buffer.write(record.read_bytes())
    elif "-dv" in arguments:
        print("TeamIdentifier=" + os.environ["ASKKEY_APPLE_TEAM_ID"], file=sys.stderr)
    elif "--sign" in arguments:
        entitlements = arguments[arguments.index("--entitlements") + 1] if "--entitlements" in arguments else None
        sign(arguments[-1], entitlements)
elif name == "df":
    print("Filesystem 1024-blocks Used Available Capacity Mounted on")
    print("/dev/synthetic 1000000000 1 900000000 1% /System/Volumes/Data")
elif name == "git":
    print("abc1234")
# swift, xcodebuild, otool and install_name_tool do nothing.
