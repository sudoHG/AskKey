#!/usr/bin/env python3
"""Check the evaluated SwiftPM target graph and local Swift imports."""

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
import subprocess
import sys


ALLOWED = {
    "AskKeySystem": set(),
    "AskKeyVault": {"AskKeySystem", "AskKeyBroker"},
    "AskKeyIntegrations": {"AskKeySystem", "AskKeyBroker"},
    "AskKeyAppKit": {"AskKeyVault", "AskKeySystem", "AskKeyIntegrations", "AskKeyBroker"},
    "AskKeyHelper": {"AskKeyBroker"},
    # Existing infrastructural edges.
    "AskKeyBroker": {"AskKeyBrokerC"},
    "AskKeyApp": {"AskKeyAppKit"},
    "AskKeyBrokerC": set(),
}

IDENT = r"(?:[A-Za-z_]\w*|`[^`]+`)"
IMPORT_RE = re.compile(
    r"(?<![\w`])import(?![\w`])\s+"
    r"(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"(" + IDENT + r")(?:\s*\.\s*" + IDENT + r")*"
)


@dataclass(frozen=True)
class Target:
    name: str
    dependencies: set[str]
    path: str


def _skip_comment(text, index):
    if text.startswith("//", index):
        end = index + 2
        while end < len(text) and text[end] not in "\r\n":
            end += 1
        return end
    if not text.startswith("/*", index):
        return None
    depth, index = 1, index + 2
    while index < len(text) and depth:
        if text.startswith("/*", index):
            depth += 1
            index += 2
        elif text.startswith("*/", index):
            depth -= 1
            index += 2
        else:
            index += 1
    if depth:
        raise ValueError("unterminated Swift block comment")
    return index


def _skip_interpolation(text, index):
    """Skip an interpolation expression, including nested strings and comments."""
    depth = 1
    while index < len(text):
        end = _skip_comment(text, index)
        if end is None:
            end = _skip_string(text, index)
        if end is not None:
            index = end
            continue
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                return index + 1
        index += 1
    raise ValueError("unterminated Swift string interpolation")


def _skip_string(text, index):
    """Return the position after a Swift ordinary, multiline or raw string."""
    start = index
    while index < len(text) and text[index] == "#":
        index += 1
    hashes = "#" * (index - start)
    if text.startswith('"""', index):
        quote = '"""'
    elif index < len(text) and text[index] == '"':
        quote = '"'
    else:
        return None
    closing = quote + hashes
    escape = "\\" + hashes
    index += len(quote)
    while index < len(text):
        if text.startswith(closing, index):
            return index + len(closing)
        if text.startswith(escape, index):
            escaped = index + len(escape)
            if text.startswith("(", escaped):
                index = _skip_interpolation(text, escaped + 1)
            else:
                index = min(len(text), escaped + 1)
        elif quote == '"' and text[index] in "\r\n":
            raise ValueError("newline in Swift single-line string")
        else:
            index += 1
    raise ValueError("unterminated Swift string literal")


def mask_literals(text):
    """Blank comments and strings while preserving line structure and offsets."""
    masked = list(text)
    index = 0
    while index < len(text):
        end = _skip_comment(text, index)
        if end is None:
            end = _skip_string(text, index)
        if end is None:
            index += 1
            continue
        for offset in range(index, end):
            if masked[offset] not in "\r\n":
                masked[offset] = " "
        index = end
    return "".join(masked)


def parse_targets(package):
    """Decode evaluated targets, rejecting output we cannot safely interpret."""
    if not isinstance(package, dict) or not isinstance(package.get("targets"), list):
        raise ValueError("swift package dump-package JSON has no targets array")
    targets = {}
    for entry in package["targets"]:
        if not isinstance(entry, dict):
            raise ValueError("invalid target in swift package dump-package JSON")
        name, kind = entry.get("name"), entry.get("type")
        if not isinstance(name, str) or not name or not isinstance(kind, str) or not kind:
            raise ValueError("target has no name or type in swift package dump-package JSON")
        path = entry.get("path")
        if path is None:
            path = f"{'Tests' if kind == 'test' else 'Sources'}/{name}"
        if not isinstance(path, str) or not path or Path(path).is_absolute() or ".." in Path(path).parts:
            raise ValueError(f"invalid source path for target {name}")
        raw_dependencies = entry.get("dependencies")
        if not isinstance(raw_dependencies, list):
            raise ValueError(f"target {name} has no dependencies array")
        dependencies = set()
        for dependency in raw_dependencies:
            if not isinstance(dependency, dict) or len(dependency) != 1:
                raise ValueError(f"invalid dependency for target {name}")
            form, values = next(iter(dependency.items()))
            if (form not in {"target", "byName", "product"} or not isinstance(values, list)
                    or not values or not isinstance(values[0], str) or not values[0]):
                raise ValueError(f"unrecognized dependency for target {name}: {form}")
            if form != "product":
                dependencies.add(values[0])
        if name in targets:
            raise ValueError(f"duplicate target in swift package dump-package JSON: {name}")
        targets[name] = Target(name, dependencies, str(Path(path)))
    return targets


def load_targets(root):
    result = subprocess.run(["swift", "package", "dump-package"], cwd=root,
                            text=True, capture_output=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ValueError(f"swift package dump-package failed (exit {result.returncode}): {detail}")
    try:
        package = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid swift package dump-package JSON: {exc}") from exc
    return parse_targets(package)


def imports_in_file(path):
    source = path.read_text(encoding="utf-8")
    code = mask_literals(source)
    return [(code.count("\n", 0, match.start()) + 1, match.group(1).strip("`"))
            for match in IMPORT_RE.finditer(code)]


def check(root):
    issues = []
    try:
        targets = load_targets(root)
    except (OSError, ValueError) as exc:
        return [f"Package.swift: {exc}"]

    production = {name: target for name, target in targets.items()
                  if name in ALLOWED or Path(target.path).parts[:1] != ("Tests",)}
    for name in sorted(production):
        if name not in ALLOWED:
            issues.append(f"Package.swift: unrecognized production target {name}")
    missing_targets = sorted(set(ALLOWED) - set(production))
    for name in missing_targets:
        issues.append(f"Package.swift: missing required production target {name}")

    local_names = set(targets)
    for name, target in sorted(production.items()):
        for dependency in sorted(target.dependencies):
            if dependency in local_names:
                if dependency not in ALLOWED.get(name, set()):
                    issues.append(f"Package.swift: forbidden dependency {name} -> {dependency}")
            elif dependency.startswith("AskKey"):
                issues.append(f"Package.swift: unknown local dependency {name} -> {dependency}")

        source_dir = root / target.path
        if not source_dir.exists():
            issues.append(f"Package.swift: production target {name} path does not exist: {target.path}")

    sources = set((root / "Sources").rglob("*.swift"))
    for target in production.values():
        sources.update((root / target.path).rglob("*.swift"))
    for source in sorted(sources):
        relative = source.relative_to(root)
        source_parts = relative.parts
        owners = [target for target in production.values()
                  if source_parts[:len(Path(target.path).parts)] == Path(target.path).parts]
        if not owners:
            issues.append(f"{relative}: source file is not owned by a production target")
            continue
        target = max(owners, key=lambda candidate: len(Path(candidate.path).parts))
        name = target.name
        permitted = ALLOWED.get(name, set())
        try:
            imports = imports_in_file(source)
        except (OSError, UnicodeError, ValueError) as exc:
            issues.append(f"{relative}: cannot scan source: {exc}")
            continue
        for line, imported in imports:
            if imported in local_names:
                if imported not in permitted:
                    issues.append(f"{relative}:{line}: forbidden import {name} -> {imported}")
                elif imported not in target.dependencies:
                    issues.append(f"{relative}:{line}: import {name} -> {imported} lacks direct manifest dependency")
            elif imported.startswith("AskKey"):
                issues.append(f"{relative}:{line}: unknown local module import {name} -> {imported}")
    return issues


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1],
                        help="repository root (defaults to this script's repository)")
    args = parser.parse_args(argv)
    issues = check(args.root.resolve())
    if issues:
        print("Module dependency violations:")
        for issue in issues:
            print(f"- {issue}")
        print(f"failed: {len(issues)} violation(s)")
        return 1
    print("Module dependency check passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
