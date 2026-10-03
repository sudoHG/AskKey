"""Exercise hygiene checks using only synthetic, temporary Git repositories."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check_hygiene.py"
spec = importlib.util.spec_from_file_location("check_hygiene", SCRIPT)
hygiene = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hygiene)


class HygieneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)

    def write(self, name, text, tracked=True):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        if tracked:
            subprocess.run(["git", "add", "--", name], cwd=self.root, check=True, capture_output=True)
        return path

    def run_check(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.root,
                              text=True, capture_output=True)

    def test_size_boundary_and_scope(self):
        self.write("Sources/AtLimit.swift", "// line\n" * 600)
        self.write("Tests/AtLimit.swift", "// line\n" * 600)
        self.write("Sources/OverLimit.swift", "// line\n" * 601)
        self.write("Tests/OverLimit.swift", "// line\n" * 601)
        self.write("scripts/Outside.swift", "// line\n" * 601)
        self.write("Sources/Other.txt", "line\n" * 601)
        self.write("Sources/Localizable.xcstrings", "line\n" * 601)
        self.assertEqual(hygiene.violations(self.root), {
            "size:Sources/OverLimit.swift", "size:Tests/OverLimit.swift",
            "size:scripts/Outside.swift"})

    def test_python_size_boundary_outside_sources_and_tests(self):
        self.write("scripts/at_limit.py", "# line\n" * 600)
        self.write("scripts/over_limit.py", "# line\n" * 601)
        self.assertEqual(hygiene.violations(self.root), {"size:scripts/over_limit.py"})

    def test_shell_size_boundary_outside_sources_and_tests(self):
        self.write("tools/at_limit.sh", "# line\n" * 600)
        self.write("tools/over_limit.sh", "# line\n" * 601)
        self.assertEqual(hygiene.violations(self.root), {"size:tools/over_limit.sh"})

    def test_c_and_header_size_boundary_anywhere_in_repository(self):
        for suffix in ("c", "h"):
            self.write(f"tools/at_limit.{suffix}", "// line\n" * 600)
            self.write(f"over_limit.{suffix}", "// line\n" * 601)
        self.assertEqual(hygiene.violations(self.root), {
            "size:over_limit.c", "size:over_limit.h"})

    def test_support_paths_and_declared_types(self):
        expected = set()
        for marker in ["E2E", "Fixture", "Probe", "RestartProof", "DebugSupport", "RealUIInput"]:
            path = f"Sources/{marker}/Ordinary.swift"
            declared = f"Sources/Declared{len(expected)}.swift"
            self.write(path, "struct Ordinary {}\n")
            self.write(declared, f"public struct Sample{marker} {{}}\n")
            expected.update({"test-support:" + path, "test-support:" + declared})
        self.write("Tests/AllowedFixture.swift", "class E2EFixture {}\n")
        self.assertEqual(hygiene.violations(self.root), expected)

    def test_support_detects_all_swift_type_declaration_kinds(self):
        for kind in ["class", "struct", "enum", "actor", "protocol", "typealias"]:
            self.write(f"Sources/{kind}.swift", f"{kind} SampleFixture {{}}\n")
        self.assertEqual(hygiene.violations(self.root), {
            f"test-support:Sources/{kind}.swift" for kind in
            ["class", "struct", "enum", "actor", "protocol", "typealias"]})

    def test_type_references_comments_and_strings_are_not_declarations(self):
        self.write("Sources/Ordinary.swift", '''
let instance: SomeFixture? = nil
// class CommentFixture {}
/* outer /* nested */ struct NestedProbe {} */
let message = "class StringFixture {}"
let raw = #"struct RawFixture {}"#
let multiline = """actor StringProbe {}"""
struct Ordinary {}
''')
        self.assertEqual(hygiene.violations(self.root), set())

    def test_debug_counts_only_sources_and_debug_directives(self):
        self.write("Sources/Ordinary.swift", "#if DEBUG\n#endif\n#if\tDEBUG\n#endif\n#if DEBUGGING\n#endif\n")
        self.write("Tests/Ordinary.swift", "#if DEBUG\n#endif\n")
        self.assertEqual(hygiene.violations(self.root), {"debug:Sources/Ordinary.swift:2"})

    def test_debug_allowlist_uses_exact_file_paths_without_counts(self):
        for name in hygiene.DEBUG_ALLOWLIST:
            self.write(name, "#if DEBUG\n#endif\n" * 3)
        self.write("Sources/Nested/DebugRunDirectory.swift", "#if DEBUG\n#endif\n")
        self.assertEqual(hygiene.violations(self.root), {
            "debug:Sources/Nested/DebugRunDirectory.swift:1"})

    def test_allowlisted_debug_file_still_rejects_test_support(self):
        name = "Sources/AskKeyBroker/DebugRunDirectory.swift"
        self.write(name, "#if DEBUG\nstruct SampleFixture {}\n#endif\n")
        self.assertEqual(hygiene.violations(self.root), {"test-support:" + name})

    def test_each_local_path_pattern(self):
        self.write("docs/user.txt", "/Users/synthetic/project\n")
        self.write("docs/temp.txt", "/private/var/synthetic\n")
        self.assertEqual(hygiene.violations(self.root), {
            "local-path:docs/user.txt", "local-path:docs/temp.txt"})

    def test_non_ascii_tracked_name(self):
        self.write("Tests/fixture-\u6d4b.txt", "synthetic\n")
        self.assertEqual(hygiene.violations(self.root), {"non-ascii-name:Tests/fixture-\u6d4b.txt"})

    def test_multica_is_case_insensitive_in_any_text_path(self):
        self.write("docs/client.txt", "MuLtIcA\n")
        self.write("Tests/client.txt", "MULTICA\n")
        self.assertEqual(hygiene.violations(self.root), {
            "multica:docs/client.txt", "multica:Tests/client.txt"})

    def test_feature_inventory_exempts_only_the_multica_check(self):
        self.write("docs/features.md", "Multica /Users/synthetic\n")
        self.write("docs/nested/features.md", "Multica\n")
        self.assertEqual(hygiene.violations(self.root), {
            "local-path:docs/features.md", "multica:docs/nested/features.md"})

    def test_only_tracked_files_are_checked(self):
        self.write("Sources/UntrackedFixture.swift", "#if DEBUG\nMultica /Users/synthetic\n", tracked=False)
        self.assertEqual(hygiene.violations(self.root), set())

    def test_cjk_scripts_are_rejected_in_tracked_text(self):
        for name, value in [("han", "\u4e2d"), ("extended-han", "\U00020000"),
                            ("hiragana", "\u3042"), ("katakana", "\u30a2"),
                            ("hangul", "\ud55c"), ("jamo", "\u1100"), ("stroke", "\u31c0"),
                            ("halfwidth-hangul", "\uffa1"), ("fullwidth-punctuation", "\uff1a")]:
            self.write(f"docs/{name}.txt", value + "\n")
        self.write("docs/english.txt", "English, caf\u00e9, and \U0001f600\n")
        self.assertEqual(hygiene.violations(self.root), {
            f"cjk:docs/{name}.txt" for name in
            ["han", "extended-han", "hiragana", "katakana", "hangul", "jamo",
             "stroke", "halfwidth-hangul", "fullwidth-punctuation"]})

    def test_cjk_exemptions_use_exact_paths_and_keep_other_rules(self):
        self.write("Sources/AskKeyAppKit/Resources/Localizable.xcstrings", "\u4e2d /Users/synthetic\n")
        self.write("README.zh-CN.md", "\u4e2d\n")
        self.write("docs/glossary.md", "\u4e2d\n")
        self.write("Sources/AskKeyAppKit/Resources/zh-Hans.lproj/InfoPlist.strings", "\u4e2d\n")
        self.write("Tests/AskKeyAppTests/AppLanguageCatalogTests.swift", "\u4e2d\n")
        for name in ["docs/README.zh-CN.md", "docs/nested/glossary.md",
                     "Sources/Nested/Localizable.xcstrings", "Tests/Nested/AppLanguageCatalogTests.swift",
                     "Sources/Nested/zh-Hans.lproj/InfoPlist.strings"]:
            self.write(name, "\u4e2d\n")
        self.assertEqual(hygiene.violations(self.root), {
            "local-path:Sources/AskKeyAppKit/Resources/Localizable.xcstrings",
            "cjk:docs/README.zh-CN.md", "cjk:docs/nested/glossary.md",
            "cjk:Sources/Nested/Localizable.xcstrings", "cjk:Tests/Nested/AppLanguageCatalogTests.swift",
            "cjk:Sources/Nested/zh-Hans.lproj/InfoPlist.strings"})

    def test_cjk_markers_with_reasons_allow_only_swift_and_python_lines(self):
        self.write("Tests/Literal.swift", 'let value = "\u4e2d" // i18n-literal: Unicode input.\n')
        self.write("Tests/Interpolation.swift", 'let value = "\\(identity("\u4e2d"))" // i18n-literal: Unicode input.\n')
        self.write("Tests/Regex.swift", 'let value = #/\u4e2d/# // i18n-literal: Unicode input.\n')
        self.write("Tests/Multiline.swift", 'let value = """\n\\(\nidentity("\u4e2d") // i18n-literal: Unicode input.\n)\n"""\n')
        self.write("scripts/literal.py", 'value = "\u4e2d" # i18n-literal: Unicode input.\n')
        self.write("docs/literal.md", '\u4e2d # i18n-literal: Unicode input.\n')
        self.assertEqual(hygiene.violations(self.root), {"cjk:docs/literal.md"})

    def test_cjk_marker_requires_a_reason_and_does_not_cover_other_lines(self):
        self.write("Tests/Empty.swift", 'let value = "\u4e2d" // i18n-literal:   \n')
        self.write("scripts/empty.py", 'value = "\u4e2d" # i18n-literal:\n')
        self.write("Tests/Other.swift", 'let value = "\u4e2d" // i18n-literal: Unicode input.\n// \u6587\n')
        self.write("Tests/Reason.swift", 'let value = "\u4e2d" // i18n-literal: \u6587\n')
        self.assertEqual(hygiene.violations(self.root), {
            "cjk:Tests/Empty.swift", "cjk:scripts/empty.py",
            "cjk:Tests/Other.swift", "cjk:Tests/Reason.swift"})

    def test_marker_text_in_strings_and_block_comments_is_not_a_line_comment(self):
        self.write("Tests/String.swift", 'let value = "\u4e2d // i18n-literal: not a comment"\n')
        self.write("Tests/Raw.swift", 'let value = #"\u4e2d // i18n-literal: not a comment"#\n')
        self.write("Tests/Block.swift", '/* \u4e2d // i18n-literal: not a line comment */\n')
        self.write("Tests/Multiline.swift", 'let value = """\n\u4e2d // i18n-literal: not a comment\n"""\n')
        self.write("Tests/Interpolation.swift", 'let value = "\\(identity("\u4e2d // i18n-literal: not a comment"))"\n')
        self.write("Tests/RawInterpolation.swift", 'let value = #"\\#(identity("\u4e2d // i18n-literal: not a comment"))"#\n')
        self.write("Tests/Regex.swift", 'let value = #/\u4e2d // i18n-literal: not a comment/#\n')
        self.write("scripts/string.py", 'value = "\u4e2d # i18n-literal: not a comment"\n')
        self.write("scripts/multiline.py", 'value = """\n\u4e2d # i18n-literal: not a comment\n"""\n')
        self.assertEqual(hygiene.violations(self.root), {
            "cjk:Tests/String.swift", "cjk:Tests/Raw.swift", "cjk:Tests/Block.swift",
            "cjk:Tests/Multiline.swift", "cjk:Tests/Interpolation.swift", "cjk:Tests/RawInterpolation.swift",
            "cjk:Tests/Regex.swift", "cjk:scripts/string.py", "cjk:scripts/multiline.py"})

    def test_brand_token_does_not_allow_other_cjk_on_the_same_line(self):
        self.write("docs/brand.txt", "\u8bf7\u65e8\n")
        self.write("docs/other.txt", "\u8bf7\u65e8\u4e2d\n")
        self.assertEqual(hygiene.violations(self.root), {"cjk:docs/other.txt"})

    def test_cjk_is_checked_in_rule_files_bom_text_and_symlink_text(self):
        for name in ["AGENTS.md", "scripts/check_hygiene.py", "Tests/Automation/test_check_hygiene.py"]:
            self.write(name, "\u4e2d\n")
        for encoding in ["utf-16", "utf-32"]:
            path = self.write(f"docs/{encoding}.txt", "")
            path.write_bytes("\u4e2d".encode(encoding))
        self.write("untracked.txt", "\u4e2d\n", tracked=False)
        link = self.root / "link.txt"
        link.symlink_to("missing-\u4e2d.txt")
        subprocess.run(["git", "add", "--", link.name], cwd=self.root, check=True, capture_output=True)
        self.assertEqual(hygiene.violations(self.root), {
            "cjk:AGENTS.md", "cjk:scripts/check_hygiene.py", "cjk:Tests/Automation/test_check_hygiene.py",
            "cjk:docs/utf-16.txt", "cjk:docs/utf-32.txt", "cjk:link.txt"})

    def test_cjk_diagnostic_does_not_disclose_file_contents(self):
        self.write("docs/input.txt", "\u4e2d synthetic private value\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "violation: cjk:docs/input.txt\n")
        self.assertNotIn("synthetic private value", result.stdout)

    def test_rule_file_exceptions_are_exact_paths(self):
        contents = "multica /Users/synthetic /private/var/synthetic\n"
        for name in ["AGENTS.md", "scripts/check_hygiene.py", "Tests/Automation/test_check_hygiene.py"]:
            self.write(name, contents)
        self.write("docs/AGENTS.md", contents)
        self.assertEqual(hygiene.violations(self.root), {
            "multica:docs/AGENTS.md", "local-path:docs/AGENTS.md"})

    def test_obsolete_baseline_has_no_pattern_exemption(self):
        name = "scripts/hygiene-baseline.txt"
        self.write(name, "multica:docs/client.txt\nlocal-path:/Users/synthetic\n")
        self.assertEqual(hygiene.violations(self.root), {
            "multica:" + name, "local-path:" + name})

    def test_binary_multica_is_checked_but_local_path_is_text_only(self):
        path = self.write("assets/image.bin", "")
        path.write_bytes(b"\x89PNG\0Multica /Users/synthetic")
        self.assertEqual(hygiene.violations(self.root), {"multica:assets/image.bin"})

    def test_binary_source_support_path_is_checked(self):
        path = self.write("Sources/Fixture/image.bin", "")
        path.write_bytes(b"\x89PNG\0")
        self.assertEqual(hygiene.violations(self.root), {"test-support:Sources/Fixture/image.bin"})

    def test_bom_encoded_text_is_checked(self):
        for encoding in ["utf-16", "utf-32"]:
            path = self.write(f"docs/{encoding}.txt", "")
            path.write_bytes("Multica /Users/synthetic".encode(encoding))
        self.assertEqual(hygiene.violations(self.root), {
            "multica:docs/utf-16.txt", "local-path:docs/utf-16.txt",
            "multica:docs/utf-32.txt", "local-path:docs/utf-32.txt"})

    def test_symlink_scans_link_text_without_reading_target(self):
        target = self.write("untracked-target.txt", "Multica /Users/synthetic\n", tracked=False)
        link = self.root / "tracked-link.txt"
        link.symlink_to(target.name)
        subprocess.run(["git", "add", "--", link.name], cwd=self.root, check=True, capture_output=True)
        self.assertEqual(hygiene.violations(self.root), set())
        target.unlink()
        self.assertEqual(hygiene.violations(self.root), set())

    def test_clean_repository_passes_without_a_baseline(self):
        self.write("Sources/AskKeyBroker/DebugRunDirectory.swift", "#if DEBUG\n#endif\n")
        self.write("Sources/AtLimit.swift", "// line\n" * 600)
        self.write("Tests/AtLimit.swift", "// line\n" * 600)
        checked = self.run_check()
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertIn("Hygiene rules passed", checked.stdout)
        self.assertFalse((self.root / "scripts/hygiene-baseline.txt").exists())

    def test_violation_fails_with_path_only_diagnostic(self):
        self.write("docs/client.txt", "Multica synthetic value\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "violation: multica:docs/client.txt\n")
        self.assertNotIn("synthetic value", result.stdout)

    def test_violation_diagnostics_are_sorted(self):
        self.write("docs/z.txt", "Multica\n")
        self.write("docs/a.txt", "/Users/synthetic\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.splitlines(), [
            "violation: local-path:docs/a.txt", "violation: multica:docs/z.txt"])

    def test_obsolete_baseline_cannot_suppress_any_fixed_rule(self):
        for name, contents, entry in [
                ("Sources/client.swift", "// line\n" * 601, "size:Sources/client.swift"),
                ("Tests/client.swift", "// line\n" * 601, "size:Tests/client.swift"),
                ("Sources/client.swift", "#if DEBUG\n#endif\n", "debug:Sources/client.swift:1"),
                ("Sources/client.swift", "struct SampleFixture {}\n", "test-support:Sources/client.swift"),
                ("Tests/client.swift", "/Users/synthetic\n", "local-path:Tests/client.swift"),
                ("Tests/fixture-\u6d4b.txt", "synthetic\n", "non-ascii-name:Tests/fixture-\u6d4b.txt"),
                ("docs/client.txt", "Multica\n", "multica:docs/client.txt")]:
            with self.subTest(entry=entry):
                self.write("scripts/hygiene-baseline.txt", entry + "\n")
                self.write(name, contents)
                result = self.run_check()
                self.assertEqual(result.returncode, 1)
                self.assertIn("violation: " + entry, result.stdout)

    def test_clean_repository_ignores_stale_baseline_entries(self):
        self.write("scripts/hygiene-baseline.txt", "size:Sources/removed.swift\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_write_baseline_option_is_rejected_without_writing(self):
        result = self.run_check("--write-baseline")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unrecognized arguments: --write-baseline", result.stderr)
        self.assertFalse((self.root / "scripts/hygiene-baseline.txt").exists())


if __name__ == "__main__":
    unittest.main()
