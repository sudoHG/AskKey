#!/usr/bin/env python3
"""Synthetic packaging tools; never contact a notary service or keychain."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

name, arguments = Path(sys.argv[0]).name, sys.argv[1:]
trace = Path(os.environ["PACKAGE_TEST_TRACE"])
with trace.open("a") as stream:
    stream.write(json.dumps([name, *arguments]) + "\n")
failure = os.environ.get("PACKAGE_TEST_FAILURE", "")
submission_ids = {
    "app": "12345678-1234-1234-1234-123456789abc",
    "dmg": "87654321-4321-4321-4321-cba987654321",
}
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
    if arguments[0] == "notarytool":
        # Poison every raw diagnostic with synthetic secrets to test redaction.
        for key in ("ASKKEY_NOTARY_PROFILE", "ASKKEY_CODESIGN_IDENTITY", "ASKKEY_APPLE_TEAM_ID",
                    "PRIVATE_KEY_FILE", "KEY_ID", "ISSUER_ID"):
            print(os.environ.get(key, ""), file=sys.stderr)
        if "--key" in arguments:
            key_path = arguments[arguments.index("--key") + 1]
            assert key_path.startswith("/dev/fd/")
            assert Path(key_path).read_bytes() == b"synthetic-private-key-bytes"
            for flag, key in (("--key-id", "KEY_ID"), ("--issuer", "ISSUER_ID")):
                assert arguments[arguments.index(flag) + 1] == os.environ[key]
            assert os.environ["PACKAGE_TEST_DELIVERED"] == "true"
            # Every later request must work even after the original file expires.
            Path(os.environ["PRIVATE_KEY_FILE"]).unlink(missing_ok=True)
        else:
            assert arguments[arguments.index("--keychain-profile") + 1] == os.environ["ASKKEY_NOTARY_PROFILE"]
        if arguments[1] == "submit":
            kind = "app" if Path(arguments[2]).suffix == ".zip" else "dmg"
            print(json.dumps({"id": submission_ids[kind]}) if failure != "invalid-json" else "{}")
            sys.exit(1 if failure == "notary-command" else 0)
        assert arguments[1] == "info"
        kind = next(kind for kind, value in submission_ids.items() if value == arguments[2])
        status = "Invalid" if failure == kind + "-notary" else "Accepted"
        print(json.dumps({"status": status, "id": submission_ids[kind]}))
        sys.exit(0)
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
    assert arguments[0] == "run" and "--" in arguments
    if failure == "approval-denied":
        sys.exit(1)
    environment = os.environ.copy()
    for key, value in (("KEY_ID", "synthetic-key-id"), ("ISSUER_ID", "synthetic-issuer-id")):
        assert key not in environment
        environment[key] = value
    environment["PACKAGE_TEST_DELIVERED"] = "true"
    assert "PRIVATE_KEY_FILE" not in environment
    with tempfile.TemporaryDirectory(prefix="synthetic-key-") as directory:
        key_file = Path(directory) / "key.p8"
        key_file.write_bytes(b"synthetic-private-key-bytes")
        environment["PRIVATE_KEY_FILE"] = str(key_file)
        result = subprocess.call(arguments[arguments.index("--") + 1:], env=environment)
    sys.exit(result)
else:
    sys.exit(1)
