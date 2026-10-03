"""Exercise the module dependency checker with synthetic temporary repos."""

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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

    def test_unrecognized_dependency_expression_fails_closed(self):
        text = manifest().replace('dependencies: ["AskKeyBroker", "AskKeySystem"]',
                                  'dependencies: [dynamicTargetDependency()]')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("unrecognized dependency for target AskKeyVault", result.stdout)

    def test_dynamic_dependency_array_fails_closed(self):
        text = manifest().replace('dependencies: ["AskKeyBroker", "AskKeySystem"]',
                                  'dependencies: dependencyList')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("dependencies for target AskKeyVault must be a literal array", result.stdout)

    def test_dynamic_target_path_fails_closed(self):
        text = manifest().replace('path: "Sources/AskKeySystem"', 'path: sourceDirectory')
        (self.root / "Package.swift").write_text(text, encoding="utf-8")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("target path for AskKeySystem must be a string literal", result.stdout)

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


if __name__ == "__main__":
    unittest.main()
