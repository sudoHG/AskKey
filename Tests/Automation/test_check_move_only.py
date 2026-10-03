"""Verify move-only comparisons in synthetic, temporary Git repositories."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check_move_only.py"


class MoveOnlyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Synthetic Tester")
        self.git("config", "user.email", "tester@example.invalid")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True,
                              text=True, capture_output=True).stdout.strip()

    def write(self, path, text):
        destination = self.root / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text, encoding="utf-8")

    def base(self, files):
        for path, text in files.items():
            self.write(path, text)
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "Synthetic base")
        return self.git("rev-parse", "HEAD")

    def check(self, *paths, base="HEAD"):
        return subprocess.run([sys.executable, str(SCRIPT), base, *paths], cwd=self.root,
                              text=True, capture_output=True)

    def assert_pass(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Move-only check: PASS", result.stdout)

    def test_pure_move_to_untracked_file_passes(self):
        self.base({"Sources/Original.swift": 'import Foundation\nstruct Value {\n'
                   '    let message = "synthetic"\n}\n'})
        (self.root / "Sources/Original.swift").unlink()
        self.write("Sources/New.swift", '// New header\nimport Swift\nstruct Value {\n'
                   '  let message = "synthetic"\n}\n')
        self.assert_pass(self.check())
        self.git("add", ".")
        self.assert_pass(self.check())

    def test_changed_literal_fails_with_original_file_and_line(self):
        self.base({"Sources/Value.swift": '// Header\nstruct Value {\nlet number = 10\n}\n'})
        self.write("Sources/Value.swift", 'struct Value {\nlet number = 11\n}\n')
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/Value.swift:3: let number = 10", result.stdout)
        self.assertIn("Other added lines (1)", result.stdout)
        self.assertIn("missing=1", result.stdout)

    def test_added_statement_fails(self):
        self.base({"Sources/Value.swift": "func run() {\nperform()\n}\n"})
        self.write("Sources/Value.swift", "func run() {\nperform()\nextra()\n}\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Other added lines (1)", result.stdout)
        self.assertIn("Sources/Value.swift:3: extra()", result.stdout)
        self.assertIn("missing=0", result.stdout)

    def test_access_widening_is_reported_and_passes(self):
        self.base({"Sources/Original.swift": "private func run() {\nperform()\n}\n"
                   "fileprivate var count = 1\ninternal struct Value {\n}\n"})
        (self.root / "Sources/Original.swift").unlink()
        self.write("Sources/New.swift", "func run() {\nperform()\n}\n"
                   "package var count = 1\npublic struct Value {\n}\n")
        result = self.check()
        self.assert_pass(result)
        self.assertIn("Access-modifier-only differences (3)", result.stdout)
        self.assertIn("access-only=3", result.stdout)
        self.assertIn("Sources/Original.swift:1: private func run() {", result.stdout)

    def test_duplicate_lines_require_every_removed_occurrence(self):
        self.base({"Sources/Value.swift": "perform()\nperform()\n"})
        self.write("Sources/Value.swift", "perform()\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/Value.swift:2: perform()", result.stdout)
        self.assertIn("missing=1", result.stdout)

    def test_access_changes_on_initializers_and_other_declarations_pass(self):
        old = ["private init(value: Int) {", "private subscript(index: Int) -> Int {",
               "private typealias Value = Int", "private nonisolated(unsafe) var value = 1"]
        self.base({"Sources/A.swift": "\n".join(old) + "\n"})
        self.write("Sources/A.swift", "\n".join(line.replace("private", "package", 1)
                   for line in old) + "\n")
        result = self.check()
        self.assert_pass(result)
        self.assertIn("access-only=4", result.stdout)

    def test_standalone_access_modifier_change_passes(self):
        self.base({"Sources/A.swift": "private\nfunc run() {\nperform()\n}\n"})
        self.write("Sources/A.swift", "internal\nfunc run() {\nperform()\n}\n")
        result = self.check()
        self.assert_pass(result)
        self.assertIn("access-only=1", result.stdout)

    def test_duplicate_moves_match_across_multiple_files(self):
        self.base({"Sources/A.swift": "perform()\nperform()\n",
                   "Tests/B.swift": "verify()\n"})
        self.write("Sources/A.swift", "")
        self.write("Tests/B.swift", "perform()\nverify()\n")
        self.write("Sources/C.swift", "perform()\n")
        self.assert_pass(self.check())

    def test_missing_location_points_to_changed_file(self):
        self.base({"Sources/A.swift": "perform()\n", "Sources/B.swift": "perform()\n"})
        self.write("Sources/B.swift", "")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/B.swift:1: perform()", result.stdout)
        self.assertNotIn("Sources/A.swift:1:", result.stdout)

    def test_ignored_lines_include_nested_block_comments(self):
        self.base({"Sources/A.swift": "import Foundation\n// Old header\n/* outer\n"
                   " nested /* comment */\n*/\n{\n}\n\nperform()\n"})
        self.write("Sources/A.swift", "@_exported import Swift\n/* replacement */\n  perform()  \n")
        self.assert_pass(self.check())

    def test_comment_markers_in_strings_are_preserved(self):
        self.base({"Sources/A.swift": 'let url = "https://example.invalid/*value*/"\n'})
        self.write("Sources/A.swift", 'let url = "https://example.invalid/*other*/"\n')
        self.assertEqual(self.check().returncode, 1)

    def test_access_words_in_strings_and_comments_are_not_access_changes(self):
        for old, new in [('let value = "private"', 'let value = "public"'),
                         ('let value = #"private"#', 'let value = #"public"#'),
                         ('let value = 1 // private', 'let value = 1 // public')]:
            with self.subTest(old=old):
                if not (self.root / "Sources/A.swift").exists():
                    self.base({"Sources/A.swift": old + "\n"})
                else:
                    self.write("Sources/A.swift", old + "\n")
                    self.git("add", ".")
                    self.git("commit", "--quiet", "-m", "Synthetic literal")
                self.write("Sources/A.swift", new + "\n")
                result = self.check()
                self.assertEqual(result.returncode, 1)
                self.assertIn("access-only=0", result.stdout)

    def test_multiline_literal_content_is_not_ignored(self):
        self.base({"Sources/A.swift": 'let value = ##"""\n// private\nimport Swift\n{\n"""##\n'})
        for content in ['// public\nimport Swift\n{', '// private\nimport Other\n{',
                        '// private\nimport Swift\n}']:
            with self.subTest(content=content):
                self.write("Sources/A.swift", 'let value = ##"""\n' + content + '\n"""##\n')
                self.assertEqual(self.check().returncode, 1)

    def test_access_like_case_and_escaped_identifier_changes_fail(self):
        self.base({"Sources/A.swift": "let choice = .private\nlet `private` = 1\n"})
        self.write("Sources/A.swift", "let choice = .public\nlet `public` = 1\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing=2", result.stdout)
        self.assertIn("access-only=0", result.stdout)

    def test_additions_are_grouped_as_declaration_headers(self):
        self.base({"Sources/A.swift": "perform()\n"})
        headers = ["extension Value {", "struct Value {", "final class Value {",
                   "enum Value {", "protocol Value {", "actor Value {"]
        self.write("Sources/A.swift", "perform()\n" + "\n".join(headers) + "\n")
        result = self.check()
        self.assert_pass(result)
        self.assertIn("Declaration headers (6)", result.stdout)

    def test_appended_let_declaration_fails(self):
        self.base({"Sources/A.swift": "perform()\n"})
        self.write("Sources/A.swift", "perform()\nlet x = 42\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/A.swift:2: let x = 42", result.stdout)
        self.assertIn("missing=0, declaration headers=0, access-only=0, other=1", result.stdout)

    def test_appended_empty_function_fails(self):
        self.base({"Sources/A.swift": "perform()\n"})
        self.write("Sources/A.swift", "perform()\nfunc f() {}\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/A.swift:2: func f() {}", result.stdout)
        self.assertIn("other=1", result.stdout)

    def test_new_extension_header_for_moved_method_passes(self):
        self.base({"Sources/Foo.swift": "struct Foo {\nfunc run() {\nperform()\n}\n}\n"})
        self.write("Sources/Foo.swift", "struct Foo {\n}\n")
        self.write("Sources/Foo+Run.swift", "@MainActor extension Foo: Runnable {\n"
                   "func run() {\nperform()\n}\n}\n")
        result = self.check()
        self.assert_pass(result)
        self.assertIn("declaration headers=1", result.stdout)

    def test_unmatched_non_type_declarations_are_other(self):
        self.base({"Sources/A.swift": "perform()\n"})
        additions = ["var value: Int", "init() {}", "case added", "package func run() {"]
        self.write("Sources/A.swift", "perform()\n" + "\n".join(additions) + "\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("declaration headers=0", result.stdout)
        self.assertIn("other=4", result.stdout)

    def test_help_describes_only_type_and_extension_headers_as_allowed(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--help"], cwd=self.root,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("Only new type and extension headers are allowed", result.stdout)
        self.assertIn("other additions and fail", result.stdout)

    def test_inline_body_and_multiple_statements_are_other_additions(self):
        self.base({"Sources/A.swift": "perform()\n"})
        self.write("Sources/A.swift", "perform()\nfunc run() { extra() }\nlet x = 1; extra()\n")
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("other=2", result.stdout)

    def test_default_and_explicit_path_scope(self):
        self.base({"Sources/A.swift": "perform()\n", "Tests/B.swift": "verify()\n",
                   "Elsewhere/C.swift": "outside()\n", "Sources/readme.txt": "ordinary\n"})
        self.write("Elsewhere/C.swift", "changed()\n")
        self.write("Sources/readme.txt", "changed\n")
        self.assert_pass(self.check())
        self.assertEqual(self.check("Elsewhere").returncode, 1)
        self.write("Tests/B.swift", "changed()\n")
        self.assert_pass(self.check("Sources/A.swift"))
        self.assertEqual(self.check().returncode, 1)

    def test_committed_head_compares_with_base_ref(self):
        base = self.base({"Sources/A.swift": "perform()\n"})
        self.git("mv", "Sources/A.swift", "Sources/B.swift")
        self.git("commit", "--quiet", "-m", "Synthetic move")
        self.assert_pass(self.check(base=base))

    def test_invalid_base_ref_is_an_error(self):
        self.base({"Sources/A.swift": "perform()\n"})
        result = self.check(base="missing-ref")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Move-only check error:", result.stderr)
        self.assertNotIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
