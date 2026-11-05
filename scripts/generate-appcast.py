#!/usr/bin/env python3
"""Write a signed Sparkle appcast with one item for a notarized release DMG.

The DMG and the feed are signed with Sparkle's sign_update from the resolved
SwiftPM artifact and verified before the feed is written, and the DMG signature
is checked against the committed public key. Release notes are embedded in the
signed feed in English and Simplified Chinese.
"""

import argparse
import base64
import binascii
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
# SwiftPM resolves this artifact at the version pinned by Package.resolved.
SIGN_UPDATE = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
PUBLIC_KEY_FILE = ROOT / "scripts/sparkle-public-key.txt"
# sign_update --verify derives the public key from the private key, so check the
# signature against the key the app ships with. CryptoKit sees no private key.
PUBLIC_KEY_CHECK = """\
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let rawKey = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
      let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
else { exit(2) }
// 3, not 1: a Swift compile failure also exits with 1.
exit(publicKey.isValidSignature(signature, for: archive) ? 0 : 3)
"""
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
RELEASES = "https://github.com/sudoHG/AskKey/releases"
MINIMUM_SYSTEM_VERSION = "14.0.0"
# Each language section starts with its marker line, English first.
NOTES_MARKERS = (("<!-- lang: en -->", "en"), ("<!-- lang: zh-Hans -->", "zh-Hans"))
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


class Failure(Exception):
    pass


def read_release_notes(path):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        raise Failure("Release notes must be a readable UTF-8 file") from None
    markers = dict(NOTES_MARKERS)
    starts = [index for index, line in enumerate(lines) if line.strip() in markers]
    if ([markers[lines[index].strip()] for index in starts] != [language for _, language in NOTES_MARKERS]
            or any(line.strip() for line in lines[:starts[0]])):
        raise Failure("Release notes must contain an English section and then a Simplified Chinese "
                      "section, each starting with its marker line: "
                      + " and ".join(marker for marker, _ in NOTES_MARKERS))
    sections = []
    for (_, language), start, end in zip(NOTES_MARKERS, starts, starts[1:] + [len(lines)]):
        text = "\n".join(lines[start + 1:end]).strip()
        if not text:
            raise Failure(f"The {language} release notes are empty")
        sections.append((language, text))
    return sections


def sign_update(*arguments):
    """Run sign_update; its output can echo key material, so it is never shown."""
    try:
        return subprocess.run([str(SIGN_UPDATE), *arguments], stdin=subprocess.DEVNULL,
                              capture_output=True)
    except OSError:
        raise Failure("Cannot run Sparkle sign_update") from None


def sign_archive(archive, key_file):
    result = sign_update("-p", "--ed-key-file", str(key_file), str(archive))
    signature = result.stdout.decode("ascii", errors="replace").strip()
    try:
        valid = result.returncode == 0 and len(base64.b64decode(signature, validate=True)) == 64
    except (binascii.Error, ValueError):
        valid = False
    if not valid:
        raise Failure("Cannot sign the DMG with the Sparkle key")
    if sign_update("--verify", "--ed-key-file", str(key_file), str(archive), signature).returncode != 0:
        raise Failure("The DMG signature did not verify")
    return signature


def read_public_key(path):
    try:
        key = "".join(Path(path).read_text(encoding="ascii").split())
        valid = len(base64.b64decode(key, validate=True)) == 32
    except (OSError, UnicodeDecodeError, binascii.Error, ValueError):
        valid = False
    if not valid:
        raise Failure("The public key file must hold one base64-encoded 32-byte EdDSA public key")
    return key


def check_public_key(public_key, signature, archive, directory):
    script = directory / "check-public-key.swift"
    script.write_text(PUBLIC_KEY_CHECK, encoding="utf-8")
    # The Swift interpreter leaves directories in TMPDIR; keep them in ours.
    scratch = directory / "swift"
    scratch.mkdir()
    environment = {key: value for key, value in os.environ.items() if key != "SPARKLE_ED_KEY_FILE"}
    environment["TMPDIR"] = str(scratch)
    try:
        result = subprocess.run(["/usr/bin/xcrun", "swift", str(script), public_key, signature,
                                 str(archive)], env=environment, stdin=subprocess.DEVNULL,
                                capture_output=True)
    except OSError:
        raise Failure("Cannot run Swift to check the DMG signature against the public key") from None
    if result.returncode == 3:
        raise Failure("The delivered Sparkle key does not match the repository public key")
    if result.returncode != 0:
        raise Failure("Cannot check the DMG signature against the public key")


def sparkle_element(parent, name, text=None):
    element = ET.SubElement(parent, f"{{{SPARKLE}}}{name}")
    element.text = text
    return element


def feed(version, length, signature, notes, critical, published):
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    for tag, text in (("title", "Ask Key"), ("link", RELEASES), ("description", "Ask Key updates")):
        ET.SubElement(channel, tag).text = text
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Ask Key {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(published)
    sparkle_element(item, "version", version)
    sparkle_element(item, "shortVersionString", version)
    sparkle_element(item, "minimumSystemVersion", MINIMUM_SYSTEM_VERSION)
    if critical:
        sparkle_element(item, "criticalUpdate")
    sparkle_element(item, "fullReleaseNotesLink", f"{RELEASES}/tag/v{version}")
    for language, text in notes:
        ET.SubElement(item, "description",
                      {f"{{{SPARKLE}}}format": "markdown", XML_LANG: language}).text = text
    ET.SubElement(item, "enclosure", {
        "url": f"{RELEASES}/download/v{version}/AskKey-{version}.dmg",
        "length": str(length),
        "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


def write_appcast(dmg, version, notes_path, key_file, output, critical, public_key_file):
    if not VERSION.fullmatch(version):
        raise Failure("Version must match X.Y.Z with numeric components")
    if dmg.name != f"AskKey-{version}.dmg" or not dmg.is_file():
        raise Failure(f"The DMG must be an existing AskKey-{version}.dmg")
    if os.path.lexists(output):
        raise Failure("The appcast output already exists")
    notes = read_release_notes(notes_path)
    public_key = read_public_key(public_key_file)
    if not (SIGN_UPDATE.is_file() and os.access(SIGN_UPDATE, os.X_OK)):
        raise Failure("Sparkle sign_update was not found; run `swift package resolve` first")
    if not (key_file.is_file() and os.access(key_file, os.R_OK)):
        raise Failure("The Sparkle private key file is missing or unreadable")
    with tempfile.TemporaryDirectory(prefix="askkey-appcast-") as directory:
        signature = sign_archive(dmg, key_file)
        check_public_key(public_key, signature, dmg, Path(directory))
        data = feed(version, dmg.stat().st_size, signature, notes, critical,
                    datetime.now(timezone.utc).replace(microsecond=0))
        # sign_update treats a path ending in .xml as a feed and embeds the signature.
        unsigned = Path(directory) / "appcast.xml"
        unsigned.write_bytes(data)
        if sign_update("--disable-signing-warning", "--ed-key-file", str(key_file),
                       str(unsigned)).returncode != 0:
            raise Failure("Cannot sign the appcast with the Sparkle key")
        if sign_update("--verify", "--ed-key-file", str(key_file), str(unsigned)).returncode != 0:
            raise Failure("The appcast signature did not verify")
        signed = unsigned.read_bytes()
    with open(output, "xb") as stream:
        stream.write(signed)


def main(argv=None):
    arguments = sys.argv[1:] if argv is None else argv
    try:
        if arguments[:1] == ["--check-release-notes"] and len(arguments) == 2:
            read_release_notes(arguments[1])
            return 0
        parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
        parser.add_argument("dmg", type=Path)
        parser.add_argument("--version", required=True)
        parser.add_argument("--release-notes", type=Path, required=True)
        parser.add_argument("--ed-key-file", type=Path, required=True)
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--critical", action="store_true")
        parser.add_argument("--public-key-file", type=Path, default=PUBLIC_KEY_FILE)
        args = parser.parse_args(arguments)
        write_appcast(args.dmg, args.version, args.release_notes, args.ed_key_file,
                      args.output, args.critical, args.public_key_file)
        return 0
    except Failure as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
