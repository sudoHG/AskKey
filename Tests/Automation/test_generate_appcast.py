"""Check the signed Sparkle appcast with synthetic Ed25519 keys and the pinned sign_update."""

import base64
from email.utils import parsedate_to_datetime
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/generate-appcast.py"
SPEC = importlib.util.spec_from_file_location("package_release_keys",
                                              ROOT / "Tests/Automation/test_package_release.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)
SIGN_UPDATE = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
VERSION = "9.8.7"
ENGLISH_NOTES = "### Added\n\n- Synthetic **English** notes & <details>."
CHINESE_NOTES = "### 新增\n\n- 合成的简体中文说明。"  # i18n-literal: synthetic Simplified Chinese release notes
RELEASE_NOTES = f"<!-- lang: en -->\n{ENGLISH_NOTES}\n\n<!-- lang: zh-Hans -->\n{CHINESE_NOTES}\n"
SIGN_UPDATE_REQUIRED = "needs the resolved Sparkle artifact; run `swift package resolve`"


def write_synthetic_key(path):
    """Write a random Ed25519 seed file the way Sparkle exports one; no keychain is involved."""
    path.write_text(base64.b64encode(os.urandom(32)).decode("ascii") + "\n", encoding="ascii")
    return path


def unchanged_outputs(test, result, directory):
    test.assertEqual(result.returncode, 1)
    test.assertFalse((directory / "appcast.xml").exists())
    test.assertEqual(list((directory / "scratch").iterdir()), [])


def verify(path, key, signature=None):
    arguments = [str(SIGN_UPDATE), "--verify", "--ed-key-file", str(key), str(path)]
    if signature is not None:
        arguments.append(signature)
    return subprocess.run(arguments, stdin=subprocess.DEVNULL, capture_output=True).returncode == 0


@unittest.skipUnless(SIGN_UPDATE.is_file(), SIGN_UPDATE_REQUIRED)
class GenerateAppcastTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="askkey-appcast-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.scratch = self.directory / "scratch"
        self.scratch.mkdir()
        seed, public_key = package.synthetic_key_pair()
        self.key = self.directory / "sparkle-key"
        self.key.write_text(seed + "\n", encoding="ascii")
        self.public_key = self.directory / "sparkle-public-key.txt"
        self.public_key.write_text(public_key + "\n", encoding="ascii")
        self.dmg = self.directory / f"AskKey-{VERSION}.dmg"
        self.dmg.write_bytes(os.urandom(4096) + b"synthetic disk image")
        self.notes = self.directory / "notes.md"
        self.notes.write_text(RELEASE_NOTES, encoding="utf-8")
        self.output = self.directory / "appcast.xml"

    def run_generator(self, *extra, key=None, notes=None, dmg=None, public_key=True):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("ASKKEY_")}
        environment["TMPDIR"] = str(self.scratch)
        if public_key is True:
            extra = ("--public-key-file", str(self.public_key), *extra)
        elif public_key:
            extra = ("--public-key-file", str(public_key), *extra)
        return subprocess.run(
            ["python3", str(SCRIPT), str(dmg or self.dmg), "--version", VERSION,
             "--release-notes", str(notes or self.notes), "--ed-key-file", str(key or self.key),
             "--output", str(self.output), *extra],
            env=environment, cwd=self.directory, text=True, capture_output=True, timeout=120)

    def item(self):
        channel = ET.parse(self.output).getroot().find("channel")
        items = channel.findall("item")
        self.assertEqual(len(items), 1)
        return items[0]

    def test_synthetic_key_produces_a_feed_that_sign_update_verifies(self):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, "")
        self.assertTrue(verify(self.output, self.key))
        item = self.item()
        self.assertEqual(item.findtext(SPARKLE + "version"), VERSION)
        self.assertEqual(item.findtext(SPARKLE + "shortVersionString"), VERSION)
        self.assertEqual(item.findtext(SPARKLE + "minimumSystemVersion"), "14.0.0")
        self.assertIsNotNone(parsedate_to_datetime(item.findtext("pubDate")).tzinfo)
        self.assertEqual(item.findtext(SPARKLE + "fullReleaseNotesLink"),
                         f"https://github.com/sudoHG/AskKey/releases/tag/v{VERSION}")
        self.assertIsNone(item.find(SPARKLE + "releaseNotesLink"))
        self.assertIsNone(item.find(SPARKLE + "criticalUpdate"))
        descriptions = {element.get(XML_LANG): (element.get(SPARKLE + "format"), element.text)
                        for element in item.findall("description")}
        self.assertEqual(descriptions, {"en": ("markdown", ENGLISH_NOTES),
                                        "zh-Hans": ("markdown", CHINESE_NOTES)})
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("url"), "https://github.com/sudoHG/AskKey/releases/download/"
                         f"v{VERSION}/AskKey-{VERSION}.dmg")
        self.assertEqual(enclosure.get("length"), str(self.dmg.stat().st_size))
        self.assertTrue(verify(self.dmg, self.key, enclosure.get(SPARKLE + "edSignature")))
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_tampered_dmg_or_feed_fails_verification(self):
        result = self.run_generator()
        self.assertEqual(result.returncode, 0, result.stderr)
        signature = self.item().find("enclosure").get(SPARKLE + "edSignature")
        with self.dmg.open("ab") as stream:
            stream.write(b"tampered")
        self.assertFalse(verify(self.dmg, self.key, signature))
        feed = self.output.read_bytes()
        self.output.write_bytes(feed.replace(f"<sparkle:version>{VERSION}<".encode(),
                                             b"<sparkle:version>9.8.8<", 1))
        self.assertNotEqual(self.output.read_bytes(), feed)
        self.assertFalse(verify(self.output, self.key))
        other = write_synthetic_key(self.directory / "other-key")
        self.output.write_bytes(feed)
        self.assertTrue(verify(self.output, self.key))
        self.assertFalse(verify(self.output, other))

    def test_critical_writes_critical_update(self):
        result = self.run_generator("--critical")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(verify(self.output, self.key))
        critical = self.item().find(SPARKLE + "criticalUpdate")
        self.assertIsNotNone(critical)
        self.assertEqual(dict(critical.attrib), {})

    def test_invalid_release_notes_are_rejected_before_signing(self):
        cases = {
            "missing Chinese": f"<!-- lang: en -->\n{ENGLISH_NOTES}\n",
            "wrong order": f"<!-- lang: zh-Hans -->\n{CHINESE_NOTES}\n<!-- lang: en -->\n{ENGLISH_NOTES}\n",
            "text before English": f"Lead\n{RELEASE_NOTES}",
            "empty English": f"<!-- lang: en -->\n\n<!-- lang: zh-Hans -->\n{CHINESE_NOTES}\n",
            "repeated marker": RELEASE_NOTES + f"<!-- lang: en -->\n{ENGLISH_NOTES}\n",
        }
        notes = self.directory / "invalid.md"
        for case, text in cases.items():
            with self.subTest(case=case):
                notes.write_text(text, encoding="utf-8")
                check = subprocess.run(["python3", str(SCRIPT), "--check-release-notes", str(notes)],
                                       text=True, capture_output=True, timeout=60)
                self.assertEqual(check.returncode, 1)
                self.assertIn("release notes", check.stderr.lower())
                result = self.run_generator(notes=notes)
                self.assertEqual(result.returncode, 1)
                self.assertFalse(self.output.exists())
        valid = subprocess.run(["python3", str(SCRIPT), "--check-release-notes", str(self.notes)],
                               text=True, capture_output=True, timeout=60)
        self.assertEqual((valid.returncode, valid.stdout, valid.stderr), (0, "", ""))

    def test_key_that_does_not_match_the_public_key_writes_nothing(self):
        # The synthetic key is valid but is not the pair of the committed public key.
        result = self.run_generator(public_key=None)
        unchanged_outputs(self, result, self.directory)
        self.assertIn("The delivered Sparkle key does not match the repository public key", result.stderr)
        self.assertNotIn(self.key.read_text(encoding="ascii").strip(), result.stdout + result.stderr)
        malformed = self.directory / "malformed-public-key.txt"
        malformed.write_text(base64.b64encode(os.urandom(31)).decode("ascii") + "\n", encoding="ascii")
        for public_key in (malformed, self.directory / "missing.txt"):
            with self.subTest(public_key=public_key.name):
                result = self.run_generator(public_key=public_key)
                unchanged_outputs(self, result, self.directory)
                self.assertIn("must hold one base64-encoded 32-byte EdDSA public key", result.stderr)

    def test_invalid_key_is_never_printed_and_writes_nothing(self):
        key = self.directory / "invalid-key"
        key.write_text("synthetic-invalid-sparkle-key-text\n", encoding="ascii")
        result = self.run_generator(key=key)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot sign the DMG", result.stderr)
        self.assertNotIn("synthetic-invalid-sparkle-key-text", result.stdout + result.stderr)
        self.assertNotIn(str(key), result.stdout + result.stderr)
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.scratch.iterdir()), [])

    def test_existing_output_or_misnamed_dmg_is_rejected(self):
        self.output.write_bytes(b"existing appcast")
        result = self.run_generator()
        self.assertEqual(result.returncode, 1)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(self.output.read_bytes(), b"existing appcast")
        self.output.unlink()
        misnamed = self.directory / "AskKey.dmg"
        misnamed.write_bytes(self.dmg.read_bytes())
        result = self.run_generator(dmg=misnamed)
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"AskKey-{VERSION}.dmg", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
