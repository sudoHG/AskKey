"""SDK marker validation must reject legacy or incomplete binary evidence."""

from contextlib import redirect_stdout
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("sdk_markers", ROOT / "scripts/check_sdk_markers.py")
MARKERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MARKERS)


def marker(sdk="27.0", platform="MACOS"):
    return f"""Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform {platform}
    minos 14.0
      sdk {sdk}
   ntools 1
     tool LD
  version 27037.1
"""


class SDKMarkerTests(unittest.TestCase):
    def test_reads_build_version_without_confusing_minimum_system_and_sdk(self):
        self.assertEqual(MARKERS.build_versions(marker()), [
            {"platform": "MACOS", "minos": "14.0", "sdk": "27.0"}
        ])

    def test_reads_every_architecture_of_a_universal_binary(self):
        self.assertEqual(len(MARKERS.build_versions(marker() + marker("26.5"))), 2)

    def test_rejects_a_universal_binary_with_one_architecture_missing_its_marker(self):
        output = "binary (architecture arm64):\n" + marker()
        output += "binary (architecture x86_64):\nLoad command 1\n cmd LC_VERSION_MIN_MACOSX\n"
        with self.assertRaisesRegex(ValueError, "for an architecture"):
            MARKERS.build_versions(output)

    def test_rejects_missing_or_old_style_load_commands(self):
        for output in ["", "Load command 1\n cmd LC_VERSION_MIN_MACOSX\n version 14.0\n sdk 27.0\n"]:
            with self.subTest(output=output), self.assertRaisesRegex(ValueError, "No macOS"):
                MARKERS.build_versions(output)

    def test_rejects_incomplete_build_version(self):
        for field in ["platform MACOS", "minos 14.0", "sdk 27.0"]:
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "missing"):
                MARKERS.build_versions(marker().replace(field, ""))

    def test_rejects_other_platforms(self):
        with self.assertRaisesRegex(ValueError, "Expected MACOS"):
            MARKERS.build_versions(marker(platform="IOS"))

    def test_rejects_invalid_version_fields(self):
        for sdk in ["unknown", "27.0.beta", "27.0.0.1"]:
            with self.subTest(sdk=sdk), self.assertRaisesRegex(ValueError, "Invalid SDK"):
                MARKERS.build_versions(marker(sdk))

    def check(self, output, expected="27.0", test_host=False):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "synthetic-binary"
            binary.touch()
            with patch.object(MARKERS.subprocess, "check_output", return_value=output), redirect_stdout(io.StringIO()):
                return MARKERS.check_binary(binary, expected, test_host=test_host)

    def test_accepts_equivalent_sdk_version_spellings(self):
        self.assertEqual(len(self.check(marker("27.0.0"))), 1)

    def test_rejects_deployment_target_misreported_as_sdk(self):
        with self.assertRaisesRegex(ValueError, "SDK mismatch"):
            self.check(marker("14.0"))

    def test_products_reject_minor_sdk_mismatches(self):
        with self.assertRaisesRegex(ValueError, "SDK mismatch"):
            self.check(marker("26.4"), expected="26.5")

    def test_apple_test_host_allows_minor_sdk_differences(self):
        self.assertEqual(len(self.check(marker("26.4"), expected="26.5", test_host=True)), 1)

    def test_apple_test_host_rejects_major_sdk_mismatches(self):
        with self.assertRaisesRegex(ValueError, "SDK major mismatch"):
            self.check(marker("14.0"), test_host=True)

    def test_apple_test_host_rejects_missing_markers(self):
        with self.assertRaisesRegex(ValueError, "No macOS"):
            self.check("", test_host=True)

    def test_rejects_a_mismatch_in_one_architecture(self):
        with self.assertRaisesRegex(ValueError, "SDK mismatch"):
            self.check(marker() + marker("14.0"))

    def test_rejects_missing_binary(self):
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(ValueError, "missing"):
            MARKERS.check_binary(Path(temporary) / "missing-binary", "27.0")

    def test_propagates_inspection_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "synthetic-binary"
            binary.touch()
            with patch.object(MARKERS.subprocess, "check_output", side_effect=subprocess.CalledProcessError(1, "vtool")):
                with self.assertRaises(subprocess.CalledProcessError):
                    MARKERS.check_binary(binary, "27.0")

    def make_test_bundle(self, directory, executable="SyntheticTests"):
        contents = Path(directory) / "SyntheticTests.xctest/Contents"
        (contents / "MacOS").mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleExecutable": executable}, output)
        return contents

    def test_bundle_with_dsym_checks_only_its_declared_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            contents = self.make_test_bundle(temporary)
            binary = contents / "MacOS/SyntheticTests"
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic Mach-O fixture")
            symbols = contents / "MacOS/SyntheticTests.dSYM/Contents/Resources/Relocations/aarch64"
            symbols.mkdir(parents=True)
            (symbols / "SyntheticTests.yml").write_text("synthetic debug relocations")
            argv = ["check_sdk_markers.py", "--test-products", temporary]
            with patch.object(MARKERS.sys, "argv", argv), \
                    patch.object(MARKERS, "selected_sdk", return_value="27.0"), \
                    patch.object(MARKERS.subprocess, "check_output", return_value=marker()) as inspect, \
                    redirect_stdout(io.StringIO()):
                self.assertEqual(MARKERS.main(), 0)
            inspect.assert_called_once_with(["xcrun", "vtool", "-show-build", str(binary)], text=True)

    def test_native_bundle_without_info_plist_finds_its_macho_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            contents = self.make_test_bundle(temporary)
            (contents / "Info.plist").unlink()
            binary = contents / "MacOS/SyntheticTests"
            binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic Mach-O fixture")
            self.assertEqual(MARKERS.test_product_binaries(temporary), [binary])

    def test_native_bundle_does_not_select_an_unrelated_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            contents = self.make_test_bundle(temporary)
            (contents / "Info.plist").unlink()
            (contents / "MacOS/Unrelated").write_bytes(b"\xcf\xfa\xed\xfe")
            with self.assertRaisesRegex(ValueError, "missing"):
                MARKERS.test_product_binaries(temporary)

    def test_bundle_discovery_accepts_macho_and_fat_headers(self):
        for header in ["feedface", "cefaedfe", "feedfacf", "cffaedfe",
                       "cafebabe", "bebafeca", "cafebabf", "bfbafeca"]:
            with self.subTest(header=header), tempfile.TemporaryDirectory() as temporary:
                contents = self.make_test_bundle(temporary, executable="DeclaredExecutable")
                binary = contents / "MacOS/DeclaredExecutable"
                binary.write_bytes(bytes.fromhex(header))
                self.assertEqual(MARKERS.test_product_binaries(temporary), [binary])

    def test_bundle_discovery_rejects_non_macho_executables_with_or_without_plist(self):
        for has_plist in [True, False]:
            for contents_bytes in [b"", b"\xcf\xfa\xed", b"synthetic text"]:
                with self.subTest(has_plist=has_plist, contents_bytes=contents_bytes), \
                        tempfile.TemporaryDirectory() as temporary:
                    contents = self.make_test_bundle(temporary)
                    if not has_plist:
                        (contents / "Info.plist").unlink()
                    (contents / "MacOS/SyntheticTests").write_bytes(contents_bytes)
                    with self.assertRaisesRegex(ValueError, "not Mach-O"):
                        MARKERS.test_product_binaries(temporary)

    def test_bundle_discovery_rejects_empty_test_products(self):
        with tempfile.TemporaryDirectory() as temporary, self.assertRaisesRegex(ValueError, "No XCTest"):
            MARKERS.test_product_binaries(temporary)

    def test_bundle_discovery_rejects_invalid_executable_metadata(self):
        for name in [None, "", "../outside-bundle", ".", ".."]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                contents = self.make_test_bundle(temporary, executable=name or "placeholder")
                properties = {} if name is None else {"CFBundleExecutable": name}
                with (contents / "Info.plist").open("wb") as output:
                    plistlib.dump(properties, output)
                with self.assertRaisesRegex(ValueError, "Invalid CFBundleExecutable"):
                    MARKERS.test_product_binaries(temporary)

    def test_bundle_discovery_rejects_missing_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            self.make_test_bundle(temporary)
            with self.assertRaisesRegex(ValueError, "missing"):
                MARKERS.test_product_binaries(temporary)


if __name__ == "__main__":
    unittest.main()
