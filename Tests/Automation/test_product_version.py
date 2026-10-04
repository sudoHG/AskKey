"""Check product version extraction and rejection of invalid version sources."""

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/product-version.sh"
SOURCE = ROOT / "Sources/AskKeyBroker/AskKeyVersion.swift"


class ProductVersionTests(unittest.TestCase):
    def run_script(self, *arguments, cwd=ROOT):
        return subprocess.run(["bash", str(SCRIPT), *map(str, arguments)],
                              cwd=cwd, text=True, capture_output=True)

    def test_real_source_prints_product_version(self):
        match = re.search(r'current = "([0-9]+\.[0-9]+\.[0-9]+)"',
                          SOURCE.read_text(encoding="utf-8"))
        self.assertIsNotNone(match)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, match.group(1) + "\n")

    def test_default_source_is_independent_of_working_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_script(cwd=temporary)
        expected = self.run_script(SOURCE)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(expected.returncode, 0, expected.stderr)
        self.assertEqual(result.stdout, expected.stdout)

    def test_explicit_source_prints_its_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "AskKeyVersion.swift"
            source.write_text('public enum AskKeyVersion {\n'
                              '    public static let current = "12.34.56"\n}\n',
                              encoding="utf-8")
            result = self.run_script(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "12.34.56\n")

    def test_malformed_versions_are_rejected(self):
        original = SOURCE.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "AskKeyVersion.swift"
            for version in ("0.1", "v0.1.0", ""):
                with self.subTest(version=version):
                    source.write_text(re.sub(r'current = "[^"]*"',
                                             f'current = "{version}"', original),
                                      encoding="utf-8")
                    result = self.run_script(source)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")

    def test_missing_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_script(Path(temporary) / "missing.swift")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
