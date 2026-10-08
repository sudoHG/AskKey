"""Validate the app's display-name plist without invoking the build script."""

from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/build-app.sh"


class AppInfoPlistTests(unittest.TestCase):
    def test_generated_plist_enables_localized_display_names(self):
        source = SCRIPT.read_text(encoding="utf-8")
        matches = re.findall(
            r'^cat > "\$APP/Contents/Info\.plist" <<PLIST\n(.*?)^PLIST$',
            source, re.MULTILINE | re.DOTALL
        )
        self.assertEqual(len(matches), 1, "Expected one app Info.plist heredoc")
        # Unexpanded bundle ID and version variables are valid plist strings.
        contents = matches[0].encode("utf-8")
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "Info.plist"
            plist.write_bytes(contents)
            result = subprocess.run(
                ["plutil", "-lint", str(plist)],
                text=True, capture_output=True
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        properties = plistlib.loads(contents)
        self.assertEqual(properties["CFBundleName"], "Ask Key")
        self.assertEqual(properties["CFBundleDisplayName"], "Ask Key")
        self.assertIs(properties["LSHasLocalizedDisplayName"], True)
        self.assertEqual(properties["CFBundleDevelopmentRegion"], "en")


if __name__ == "__main__":
    unittest.main()
