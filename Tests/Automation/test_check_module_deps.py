"""Exercise the module dependency checker with synthetic temporary repos."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check_module_deps.py"
spec = importlib.util.spec_from_file_location("check_module_deps", SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


TARGETS = {
    "AskKeySystem": set(),
    "AskKeyVault": {"AskKeySystem", "AskKeyBroker"},
    "AskKeyIntegrations": {"AskKeySystem", "AskKeyBroker"},
    "AskKeyAppKit": {"AskKeyVault", "AskKeySystem", "AskKeyIntegrations", "AskKeyBroker"},
    "AskKeyHelper": {"AskKeyBroker"},
    "AskKeyBroker": {"AskKeyBrokerC"},
    "AskKeyApp": {"AskKeyAppKit"},
    "AskKeyBrokerC": set(),
}


def manifest(targets=None, extra=""):
    targets = TARGETS if targets is None else targets
    entries = []
    for name, dependencies in targets.items():
        deps = ", ".join(f'"{dependency}"' for dependency in sorted(dependencies))
        entries.append(f'.target(name: "{name}", dependencies: [{deps}], path: "Sources/{name}")')
    target_entries = ",\n".join(entries)
    if extra and target_entries:
        target_entries += ",\n"
    return """// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Synthetic",
    products: [.executable(name: "SyntheticApp", targets: ["AskKeyApp"])],
    dependencies: [.package(path: "GRDB.swift"), .package(path: "External")],
    targets: [
""" + target_entries + extra + "\n    ]\n)\n"


class ModuleDependencyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "Package.swift").write_text(manifest(), encoding="utf-8")
        for target in TARGETS:
            (self.root / "Sources" / target).mkdir(parents=True, exist_ok=True)

    def write(self, target, contents, name="Module.swift"):
        path = self.root / "Sources" / target / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def run_check(self):
        return subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root)],
                              text=True, capture_output=True)

    def test_existing_edges_and_external_products_pass(self):
        targets = {name: set(dependencies) for name, dependencies in TARGETS.items()}
        targets["AskKeyVault"].add("GRDB")
        text = manifest(targets).replace('dependencies: ["AskKeyBroker", "AskKeySystem", "GRDB"]',
                                        'dependencies: ["AskKeyBroker", "AskKeySystem", '
                                        '.product(name: "GRDB", package: "GRDB.swift")]')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        self.write("AskKeyBroker", "import Foundation\nimport AskKeyBrokerC\n")
        self.write("AskKeyVault", "import CryptoKit\nimport GRDB\nimport AskKeyBroker\nimport AskKeySystem\n")
        self.write("AskKeyAppKit", "import SwiftUI\nimport AskKeyVault\n")
        self.write("AskKeyHelper", "import AskKeyBroker\n")
        self.write("AskKeyApp", "import AskKeyAppKit\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_forbidden_manifest_edge_fails(self):
        targets = {name: set(dependencies) for name, dependencies in TARGETS.items()}
        targets["AskKeyVault"].add("AskKeyAppKit")
        text = manifest(targets)
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("forbidden dependency AskKeyVault -> AskKeyAppKit", result.stdout)

    def test_forbidden_actual_import_fails_even_when_manifest_is_clean(self):
        path = self.write("AskKeySystem", "import AskKeyVault\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"{path.relative_to(self.root)}:1: forbidden import AskKeySystem -> AskKeyVault",
                      result.stdout)

    def test_second_import_after_semicolon_is_checked(self):
        self.write("AskKeySystem", "import Foundation; import AskKeyVault\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("forbidden import AskKeySystem -> AskKeyVault", result.stdout)

    def test_allowed_import_requires_direct_manifest_dependency(self):
        self.write("AskKeyVault", "@testable import AskKeySystem\n")
        targets = {name: set(dependencies) for name, dependencies in TARGETS.items()}
        targets["AskKeyVault"].remove("AskKeySystem")
        text = manifest(targets)
        text = text.replace('dependencies: ["AskKeyBroker"]',
                            'dependencies: ["AskKeyBroker", '
                            '.product(name: "AskKeySystem", package: "External")]')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("import AskKeyVault -> AskKeySystem lacks direct manifest dependency", result.stdout)

    def test_nested_target_dependency_to_test_support_is_an_edge_not_a_target_declaration(self):
        targets = {name: set(dependencies) for name, dependencies in TARGETS.items()}
        targets["AskKeyVault"].remove("AskKeySystem")
        text = manifest(targets, extra=(
            '.target(name: "AskKeyTestSupport", path: "Tests/AskKeyTestSupport")'))
        text = text.replace('.target(name: "AskKeyVault", dependencies: ["AskKeyBroker"],',
                            '.target(name: "AskKeyVault", dependencies: ["AskKeyBroker", '
                            '.target(name: "AskKeyTestSupport")],')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        (self.root / "Tests/AskKeyTestSupport").mkdir(parents=True)
        self.write("AskKeyVault", "import AskKeyTestSupport\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("forbidden dependency AskKeyVault -> AskKeyTestSupport", result.stdout)
        self.assertIn("forbidden import AskKeyVault -> AskKeyTestSupport", result.stdout)
        self.assertNotIn("unrecognized production target AskKeyTestSupport", result.stdout)

    def test_bare_dependency_with_leading_and_trailing_comments_is_recognized(self):
        text = manifest().replace(
            'dependencies: ["AskKeyBroker", "AskKeySystem"]',
            'dependencies: [/* before */ "AskKeyBroker" /* between */,\n'
            '                // next dependency\n                "AskKeySystem" /* after */]')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        self.write("AskKeyVault", "import AskKeySystem\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_invalid_manifest_command_fails_closed(self):
        text = manifest().replace('dependencies: ["AskKeyBroker", "AskKeySystem"]',
                                  'dependencies: [dynamicTargetDependency()]')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("swift package dump-package failed", result.stdout)
        self.assertNotIn("Module dependency check passed", result.stdout)

    def test_evaluated_dependency_array_passes(self):
        text = manifest().replace('dependencies: ["AskKeyBroker", "AskKeySystem"]',
                                  'dependencies: dependencyList')
        text = text.replace('let package = Package(',
                            'let dependencyList: [Target.Dependency] = ["AskKeyBroker", "AskKeySystem"]\n'
                            'let package = Package(')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_evaluated_target_path_passes(self):
        text = manifest().replace('path: "Sources/AskKeySystem"', 'path: sourceDirectory')
        text = text.replace('let package = Package(',
                            'let sourceDirectory = "Sources/AskKeySystem"\nlet package = Package(')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_comments_after_target_argument_labels_are_skipped(self):
        text = manifest().replace('name: "AskKeySystem"', 'name: /* name */ "AskKeySystem"')
        text = text.replace('path: "Sources/AskKeySystem"', 'path: /* path */ "Sources/AskKeySystem"')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_test_target_without_explicit_path_defaults_to_tests(self):
        text = manifest(extra='.testTarget(name: "AskKeySupportTests")')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_attributed_and_qualified_imports_use_root_module(self):
        self.write("AskKeyAppKit", "@_spi(Internal) @preconcurrency import AskKeySystem.Submodule\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_comments_and_strings_do_not_create_imports_or_manifest_targets(self):
        self.write("AskKeySystem", '''
// import AskKeyAppKit
/* nested /* import AskKeyVault */ still a comment */
let message = """
import AskKeyHelper
"""
''')
        with (self.root / "Package.swift").open("a", encoding="utf-8") as package:
            package.write('let example = #".target(name: "Fake", path: "Sources/Fake")"#\n')
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_quote_in_comment_does_not_hide_a_real_import(self):
        self.write("AskKeySystem", '// "an unfinished-looking string\nimport AskKeyVault\n')
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("forbidden import AskKeySystem -> AskKeyVault", result.stdout)

    def test_raw_string_backslash_does_not_escape_closing_delimiter(self):
        source = '\n'.join([
            r'let oneHash = #"backslash \"#',
            r'let twoHashes = ##"backslash \"##',
            "import AskKeyVault",
            "",
        ])
        self.write("AskKeySystem", source)
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("forbidden import AskKeySystem -> AskKeyVault", result.stdout)

    def test_ordinary_escaped_quote_stays_inside_string(self):
        source = 'let message = "escaped quote: \\" import AskKeyVault"\n'
        self.write("AskKeySystem", source)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_unknown_askkey_dependency_and_import_fail_closed(self):
        targets = {name: set(dependencies) for name, dependencies in TARGETS.items()}
        targets["AskKeySystem"].add("AskKeyFuture")
        (self.root / "Package.swift").write_text(manifest(targets), encoding="utf-8")
        self.write("AskKeySystem", "import AskKeyFuture\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("unknown local dependency AskKeySystem -> AskKeyFuture", result.stdout)
        self.assertIn("unknown local module import AskKeySystem -> AskKeyFuture", result.stdout)

    def test_unowned_source_file_under_sources_fails(self):
        path = self.root / "Sources/AskKeyUntracked/Orphan.swift"
        path.parent.mkdir(parents=True)
        path.write_text("import Foundation\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Sources/AskKeyUntracked/Orphan.swift: source file is not owned", result.stdout)

    def test_unknown_production_target_fails_closed(self):
        text = manifest(extra='        .target(name: "AskKeyExtras", path: "Sources/AskKeyExtras")')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        (self.root / "Sources/AskKeyExtras").mkdir()
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("unrecognized production target AskKeyExtras", result.stdout)

    def assert_evaluated_forbidden_edge(self, text):
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        dumped = subprocess.run(["swift", "package", "dump-package"], cwd=self.root,
                                text=True, capture_output=True)
        self.assertEqual(dumped.returncode, 0, dumped.stdout + dumped.stderr)
        targets = checker.parse_targets(json.loads(dumped.stdout))
        self.assertIn("AskKeyVault", targets["AskKeyIntegrations"].dependencies)
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("forbidden dependency AskKeyIntegrations -> AskKeyVault", result.stdout)

    def test_conditional_dependency_uses_actual_swiftpm_edge(self):
        text = manifest().replace(
            '.target(name: "AskKeyIntegrations", dependencies: ["AskKeyBroker", "AskKeySystem"],',
            '.target(name: "AskKeyIntegrations", dependencies: '
            '[false ? .target(name: "AskKeySystem") : .target(name: "AskKeyVault")],')
        self.assert_evaluated_forbidden_edge(text)

    def test_typed_targets_map_uses_actual_swiftpm_edge(self):
        text = manifest().replace('\n    ]\n)', '''
    ].map { (target: Target) -> Target in
        if target.name == "AskKeyIntegrations" {
            target.dependencies.append(.target(name: "AskKeyVault"))
        }
        return target
    }
)''')
        self.assert_evaluated_forbidden_edge(text)

    def test_interpolated_comment_text_does_not_hide_following_import(self):
        self.write("AskKeySystem", 'let message = "\\(String("/*"))"\nimport AskKeyVault\n')
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Module.swift:2: forbidden import AskKeySystem -> AskKeyVault", result.stdout)

    def test_production_sources_at_evaluated_custom_path_are_checked(self):
        text = manifest().replace('path: "Sources/AskKeySystem"', 'path: "Custom/System"')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        path = self.root / "Custom/System/Module.swift"
        path.parent.mkdir(parents=True)
        path.write_text("import AskKeyVault\n", encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Custom/System/Module.swift:1: forbidden import", result.stdout)

    def test_source_lexing_error_fails_closed(self):
        self.write("AskKeySystem", 'let message = "unfinished\nimport AskKeyVault\n')
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("cannot scan source: newline in Swift single-line string", result.stdout)

    def test_forbidden_imports_with_attributes_access_and_kind_fail(self):
        forms = ["@testable import", "@_exported import", "@_spi(Internal) import",
                 "private import", "fileprivate import", "internal import", "package import",
                 "public import", "import struct", "import func"]
        self.write("AskKeySystem", "\n".join(form + " AskKeyVault.Member" for form in forms) + "\n")
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("forbidden import AskKeySystem -> AskKeyVault"), len(forms))

    def test_dump_command_failure_never_falls_back_to_manifest_text(self):
        result = subprocess.CompletedProcess([], 1, '{"targets": []}', "synthetic failure")
        with mock.patch.object(checker.subprocess, "run", return_value=result) as run:
            issues = checker.check(self.root)
        run.assert_called_once_with(["swift", "package", "dump-package"], cwd=self.root,
                                    text=True, capture_output=True)
        self.assertEqual(len(issues), 1)
        self.assertIn("swift package dump-package failed (exit 1): synthetic failure", issues[0])

    def test_unavailable_swift_command_fails_closed(self):
        with mock.patch.object(checker.subprocess, "run", side_effect=FileNotFoundError("swift missing")):
            self.assertEqual(checker.check(self.root), ["Package.swift: swift missing"])

    def test_invalid_dump_output_fails_closed(self):
        for output in ["not JSON", "null", "{}", '{"targets": null}', '{"targets": [null]}']:
            with self.subTest(output=output):
                result = subprocess.CompletedProcess([], 0, output, "")
                with mock.patch.object(checker.subprocess, "run", return_value=result):
                    self.assertTrue(checker.check(self.root))

    def test_unsupported_dump_dependency_fails_closed(self):
        package = {"targets": [{"name": "AskKeySystem", "type": "regular",
                                "dependencies": [{"futureDependency": ["AskKeyVault"]}]}]}
        result = subprocess.CompletedProcess([], 0, json.dumps(package), "")
        with mock.patch.object(checker.subprocess, "run", return_value=result):
            self.assertIn("unrecognized dependency for target AskKeySystem", checker.check(self.root)[0])


class SwiftImportLexerTests(unittest.TestCase):
    def scan(self, source, parse=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Module.swift"
            path.write_text(source, encoding="utf-8")
            if parse:
                result = subprocess.run(["swiftc", "-parse", str(path)], text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return checker.imports_in_file(path)

    def test_all_import_forms_find_root_module_and_import_line(self):
        forms = [
            "import AskKeyVault", "@testable import AskKeyVault", "@_exported import AskKeyVault",
            "@_spi(Internal) @preconcurrency import AskKeyVault.Submodule",
            "@testable\nimport AskKeyVault", "import `AskKeyVault`",
        ]
        forms += [f"{access} import AskKeyVault" for access in
                  ["private", "fileprivate", "internal", "package", "public"]]
        forms += [f"import {kind} AskKeyVault.Member" for kind in
                  ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]]
        for form in forms:
            with self.subTest(form=form):
                self.assertEqual(self.scan(form + "\n"), [(form.count("\n") + 1, "AskKeyVault")])

    def test_same_line_import_after_statement_is_checked(self):
        self.assertEqual(self.scan('let message = "text"; @_exported import AskKeyVault\n'),
                         [(1, "AskKeyVault")])

    def test_comments_preserve_following_import_and_offsets(self):
        source = '/* " /* import AskKeyVault */ ) */\n// " /* import AskKeyVault\nimport AskKeyVault\n'
        masked = checker.mask_literals(source)
        self.assertEqual(len(masked), len(source))
        self.assertEqual([i for i, char in enumerate(masked) if char == "\n"],
                         [i for i, char in enumerate(source) if char == "\n"])
        self.assertEqual(self.scan(source), [(3, "AskKeyVault")])

    def test_nested_interpolation_strings_comments_and_parentheses(self):
        literals = [
            r'"\(String("/*"))"',
            r'"\(String("//"))"',
            r'"\(String("\(String("/*"))"))"',
            r'"\(String(") /* import AskKeyVault"))"',
            r'"\((1 /* ) " /* nested */ */ + 2))"',
            '"""\n\\(1 // ) " /*\n + 2)\n"""',
            r'#"\#(String("/*"))"#',
            r'##"\##(String(#"/* )"#))"##',
            '"""\n\\(String("/*"))\nimport AskKeyVault\n"""',
            '#"""\n\\#(String("/*"))\nimport AskKeyVault\n"""#',
            '##"""\n\\##(String("\\(String("/*"))"))\nimport AskKeyVault\n"""##',
            '"\\(String("""\n/* )\n"""))"',
            '"\\(String(#"""\n/* )\n"""#))"',
        ]
        for literal in literals:
            with self.subTest(literal=literal):
                source = "let message = " + literal + "\nimport AskKeyVault\n"
                self.assertEqual(self.scan(source, parse=True), [(literal.count("\n") + 2, "AskKeyVault")])

    def test_raw_string_requires_matching_hash_count_for_escapes_and_interpolation(self):
        literals = [
            r'#"literal \( and /* import AskKeyVault"#',
            r'##"literal \#( and /* import AskKeyVault"##',
            r'#"escaped quote \#" import AskKeyVault"#',
            r'##"escaped quote \##" import AskKeyVault"##',
            r'##"short delimiter "# import AskKeyVault"##',
        ]
        for literal in literals:
            with self.subTest(literal=literal):
                self.assertEqual(self.scan("let message = " + literal + "\nimport AskKeyVault\n", parse=True),
                                 [(2, "AskKeyVault")])

    def test_import_word_inside_identifiers_and_literals_is_ignored(self):
        source = 'let `import` = "import AskKeyVault"\nlet importValue = 1\nlet message = #"/*"#\n'
        self.assertEqual(self.scan(source), [])

    def test_unterminated_comments_strings_and_interpolation_fail_closed(self):
        for source in ['/* unfinished', '"unfinished', '#"unfinished', '"\\(1',
                       '"\\(1 /* unfinished', '"""\nunfinished']:
            with self.subTest(source=source):
                with self.assertRaises(ValueError):
                    self.scan(source)


if __name__ == "__main__":
    unittest.main()
