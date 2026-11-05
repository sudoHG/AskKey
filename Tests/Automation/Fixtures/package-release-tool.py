#!/usr/bin/env python3
"""Synthetic packaging tools; never contact a notary service or keychain."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

name, arguments = Path(sys.argv[0]).name, sys.argv[1:]
configuration_path = Path(sys.argv[0]).parent / "target-config.json"
configuration = os.environ if "PACKAGE_TEST_TRACE" in os.environ else json.loads(configuration_path.read_text())
trace = Path(configuration["PACKAGE_TEST_TRACE"])
with trace.open("a") as stream:
    stream.write(json.dumps([name, *arguments]) + "\n")
failure = configuration.get("PACKAGE_TEST_FAILURE", "")
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
            assert not key_path.startswith("/dev/fd/")
            assert Path(key_path).read_bytes() == b"synthetic-private-key-bytes"
            for flag, key in (("--key-id", "KEY_ID"), ("--issuer", "ISSUER_ID")):
                assert arguments[arguments.index(flag) + 1] == os.environ[key]
            assert not any(key.startswith(("ASKKEY_", "PACKAGE_TEST_")) for key in os.environ)
        else:
            assert arguments[arguments.index("--keychain-profile") + 1] == os.environ["ASKKEY_NOTARY_PROFILE"]
        if arguments[1] == "submit":
            kind = "app" if Path(arguments[2]).suffix == ".zip" else "dmg"
            print(json.dumps({"id": submission_ids[kind]}) if failure != "invalid-json" else "{}")
            sys.exit(1 if failure == "notary-command" else 0)
        assert arguments[1] == "info"
        if failure == "interrupt-info":
            Path(configuration["PACKAGE_TEST_READY"]).touch()
            time.sleep(120)
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
    sparkle = arguments[arguments.index("--credential") + 1] == "synthetic-sparkle-key"
    if failure == ("sparkle-approval-denied" if sparkle else "approval-denied"):
        sys.exit(1)
    # Pass test control data through a local fixture file, not the target env.
    configuration_path.write_text(json.dumps({key: os.environ[key] for key in (
        "PACKAGE_TEST_TRACE", "PACKAGE_TEST_FAILURE", "PACKAGE_TEST_READY") if key in os.environ}))
    environment = {key: value for key, value in os.environ.items()
                   if key in ("HOME", "PATH", "TMPDIR", "LANG", "TERM", "SHELL", "USER", "LOGNAME")
                   or key.startswith("LC_")}
    if not sparkle:
        for key, value in (("KEY_ID", "synthetic-key-id"), ("ISSUER_ID", "synthetic-issuer-id")):
            assert key not in environment
            environment[key] = value
    variable = "SPARKLE_ED_KEY_FILE" if sparkle else "PRIVATE_KEY_FILE"
    assert variable not in environment
    key_root, = Path(environment["TMPDIR"]).glob("askkey-package-release.*")
    prefix = "synthetic-sparkle-key-" if sparkle else "synthetic-key-"
    with tempfile.TemporaryDirectory(prefix=prefix, dir=key_root) as directory:
        key_file = Path(directory) / ("key" if sparkle else "key.p8")
        if sparkle:
            # The test's synthetic Ed25519 seed file; no keychain item exists.
            key_file.write_bytes(Path(os.environ["PACKAGE_TEST_SPARKLE_KEY"]).read_bytes())
        else:
            key_file.write_bytes(b"synthetic-private-key-bytes")
        environment[variable] = str(key_file)
        if failure == "delivery-missing":
            key_file.unlink()
        command = arguments[arguments.index("--") + 1:]
        if sparkle:
            # Check against the synthetic pair, not the committed public key.
            command += ["--public-key-file", os.environ["PACKAGE_TEST_SPARKLE_PUBLIC_KEY"]]
        result = subprocess.call(command, env=environment)
    sys.exit(result)
else:
    sys.exit(1)
