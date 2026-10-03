#!/usr/bin/env python3
"""Check local Swift module dependencies without invoking SwiftPM."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
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
    r"(?m)(?:^|;)\s*(?:(?:@\w+(?:\.\w+)*(?:\([^\n]*?\))?|"
    r"private|fileprivate|internal|package|public)\s+)*"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"(" + IDENT + r")(?:\s*\.\s*" + IDENT + r")*"
)


@dataclass(frozen=True)
class Target:
    name: str
    dependencies: set[str]
    path: str


def _skip_string(text, index):
    """Return the position after a Swift quoted or raw quoted string."""
    start = index
    while index < len(text) and text[index] == "#":
        index += 1
    hashes = index - start
    if text.startswith('"""', index):
        quote = '"""'
    elif index < len(text) and text[index] == '"':
        quote = '"'
    else:
        return None
    end = quote + "#" * hashes
    index += len(quote)
    while index < len(text):
        if text.startswith(end, index):
            return index + len(end)
        if text[index] == "\\":
            escape_end = index + 1
            if hashes == 0:
                index = min(len(text), escape_end + 1)
                continue
            matched_hashes = 0
            while (matched_hashes < hashes and escape_end < len(text)
                   and text[escape_end] == "#"):
                matched_hashes += 1
                escape_end += 1
            if matched_hashes == hashes and escape_end < len(text):
                # Raw-string escapes require the literal's complete hash prefix.
                index = escape_end + 1
            else:
                index += 1
        else:
            index += 1
    return len(text)


def mask_literals(text):
    """Blank comments and strings while preserving line structure and offsets."""
    masked = list(text)
    i = 0
    while i < len(text):
        end = _skip_string(text, i)
        if end is not None:
            for j in range(i, end):
                if masked[j] != "\n":
                    masked[j] = " "
            i = end
        elif text.startswith("//", i):
            end = text.find("\n", i)
            if end < 0:
                end = len(text)
            for j in range(i, end):
                masked[j] = " "
            i = end
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            for k in range(i, j):
                if masked[k] != "\n":
                    masked[k] = " "
            i = j
        else:
            i += 1
    return "".join(masked)


def balanced_end(text, opening):
    """Find the matching delimiter, ignoring delimiters in comments/strings."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[text[opening]]]
    i = opening + 1
    while i < len(text) and stack:
        string_end = _skip_string(text, i)
        if string_end is not None:
            i = string_end
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            i = len(text) if newline < 0 else newline + 1
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            i = j
        elif text[i] in pairs:
            stack.append(pairs[text[i]])
            i += 1
        elif text[i] == stack[-1]:
            stack.pop()
            i += 1
        else:
            i += 1
    return i if not stack else None


def swift_strings(text):
    """Return ordinary Swift string literal values in a source fragment."""
    values, i = [], 0
    while i < len(text):
        end = _skip_string(text, i)
        if end is None:
            i += 1
            continue
        raw = text[i:end]
        hashes = len(raw) - len(raw.lstrip("#"))
        quote_offset = hashes
        quote = '"""' if raw.startswith('"""', quote_offset) else '"'
        value = raw[quote_offset + len(quote):-len(quote) - hashes if hashes else -len(quote)]
        values.append(value)
        i = end
    return values


def first_string_after(text, offset):
    offset = skip_trivia(text, offset)
    end = _skip_string(text, offset)
    if end is None:
        return None
    values = swift_strings(text[offset:end])
    return values[0] if values else None


def split_top_level(text, separator=","):
    """Split a Swift argument list at separators outside nested syntax."""
    pieces, start, stack, i = [], 0, [], 0
    pairs = {"(": ")", "[": "]", "{": "}"}
    while i < len(text):
        string_end = _skip_string(text, i)
        if string_end is not None:
            i = string_end
        elif text.startswith("//", i):
            newline = text.find("\n", i)
            i = len(text) if newline < 0 else newline + 1
        elif text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                if text.startswith("/*", j):
                    depth += 1
                    j += 2
                elif text.startswith("*/", j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            i = j
        elif text[i] in pairs:
            stack.append(pairs[text[i]])
            i += 1
        elif stack and text[i] == stack[-1]:
            stack.pop()
            i += 1
        elif not stack and text[i] == separator:
            pieces.append(text[start:i])
            start = i + 1
            i += 1
        else:
            i += 1
    pieces.append(text[start:])
    return pieces


def named_arguments(block):
    """Map top-level labeled call arguments without inspecting nested calls."""
    result = {}
    for argument in split_top_level(block):
        code = mask_literals(argument)
        match = re.match(r"\s*([A-Za-z_]\w*)\s*:", code)
        if not match:
            continue
        name = match.group(1)
        if name in result:
            raise ValueError(f"duplicate target argument: {name}")
        result[name] = (argument, match.end())
    return result


def array_value(text, offset, description):
    opening = skip_trivia(text, offset)
    if opening >= len(text) or text[opening] != "[":
        raise ValueError(f"{description} must be a literal array")
    end = balanced_end(text, opening)
    if end is None or skip_trivia(text, end) != len(text):
        raise ValueError(f"{description} has unbalanced or trailing syntax")
    return text[opening + 1:end - 1]


def skip_trivia(text, offset=0):
    while offset < len(text):
        if text[offset].isspace():
            offset += 1
        elif text.startswith("//", offset):
            newline = text.find("\n", offset)
            offset = len(text) if newline < 0 else newline + 1
        elif text.startswith("/*", offset):
            depth, cursor = 1, offset + 2
            while cursor < len(text) and depth:
                if text.startswith("/*", cursor):
                    depth += 1
                    cursor += 2
                elif text.startswith("*/", cursor):
                    depth -= 1
                    cursor += 2
                else:
                    cursor += 1
            if depth:
                raise ValueError("unclosed comment in Package.swift")
            offset = cursor
        else:
            break
    return offset


def parse_target_entry(entry):
    entry_code = mask_literals(entry)
    call_match = re.match(
        r"\s*\.(?P<kind>target|executableTarget|testTarget|macro|systemLibraryTarget|binaryTarget)\s*\(",
        entry_code)
    if not call_match:
        raise ValueError(f"unrecognized entry in Package.targets: {entry.strip()[:80]}")
    opening = entry_code.find("(", call_match.start())
    end = balanced_end(entry, opening)
    if end is None or entry_code[end:].strip():
        raise ValueError("unbalanced or trailing syntax in target declaration")
    block = entry[opening + 1:end - 1]
    arguments = named_arguments(block)
    if "name" not in arguments:
        raise ValueError("target declaration has no name")
    name_text, name_offset = arguments["name"]
    target_name = first_string_after(name_text, name_offset)
    if target_name is None:
        raise ValueError("target declaration has no literal name")
    path_value = None
    if "path" in arguments:
        path_text, path_offset = arguments["path"]
        path_value = first_string_after(path_text, path_offset)
        if path_value is None:
            raise ValueError(f"target path for {target_name} must be a string literal")
    default_root = "Tests" if call_match.group("kind") == "testTarget" else "Sources"
    path = path_value or f"{default_root}/{target_name}"
    dependencies = set()
    if "dependencies" in arguments:
        dep_text, dep_offset = arguments["dependencies"]
        dep_block = array_value(dep_text, dep_offset, f"dependencies for target {target_name}")
        for raw_entry in split_top_level(dep_block):
            entry_start = skip_trivia(raw_entry)
            if entry_start == len(raw_entry):
                continue
            literal_end = _skip_string(raw_entry, entry_start)
            if literal_end is not None:
                if mask_literals(raw_entry[literal_end:]).strip():
                    raise ValueError(f"unrecognized dependency for target {target_name}")
                values = swift_strings(raw_entry[entry_start:literal_end])
                if not values:
                    raise ValueError(f"invalid dependency for target {target_name}")
                dependencies.add(values[0])
                continue

            dep_code = mask_literals(raw_entry)
            local_arg = re.search(r"\.(?:target|byName|plugin)\s*\(\s*name\s*:", dep_code)
            if local_arg:
                value = first_string_after(raw_entry, local_arg.end())
                if value is None:
                    raise ValueError(f"non-literal local dependency in target {target_name}")
                dependencies.add(value)
                continue
            if re.match(r"\s*\.product\s*\(", dep_code):
                product_name = re.search(r"\bname\s*:", dep_code)
                package_name = re.search(r"\bpackage\s*:", dep_code)
                if (product_name is None or package_name is None
                        or first_string_after(raw_entry, product_name.end()) is None
                        or first_string_after(raw_entry, package_name.end()) is None):
                    raise ValueError(f"unrecognized external product dependency in target {target_name}")
                continue
            raise ValueError(f"unrecognized dependency for target {target_name}: {raw_entry.strip()[:80]}")
    return Target(target_name, dependencies, path)


def parse_targets(manifest):
    code = mask_literals(manifest)
    targets = {}
    package_match = re.search(r"\bPackage\s*\(", code)
    if not package_match:
        raise ValueError("Package initializer not found")
    package_open = code.find("(", package_match.start())
    package_end = balanced_end(manifest, package_open)
    if package_end is None:
        raise ValueError("unbalanced Package initializer")
    package_body = manifest[package_open + 1:package_end - 1]
    targets_argument = None
    for argument in split_top_level(package_body):
        argument_code = mask_literals(argument)
        if re.match(r"\s*targets\s*:", argument_code):
            targets_argument = argument
            break
    if targets_argument is None:
        raise ValueError("Package.targets array not found")
    targets_code = mask_literals(targets_argument)
    targets_match = re.match(r"\s*targets\s*:", targets_code)
    array_open = targets_code.find("[", targets_match.end())
    if array_open < 0 or targets_code[targets_match.end():array_open].strip():
        raise ValueError("Package.targets is not an array")
    array_end = balanced_end(targets_argument, array_open)
    if array_end is None:
        raise ValueError("unbalanced Package.targets array")
    for entry in split_top_level(targets_argument[array_open + 1:array_end - 1]):
        if not mask_literals(entry).strip():
            continue
        target = parse_target_entry(entry)
        if target.name in targets:
            raise ValueError(f"duplicate target declaration: {target.name}")
        targets[target.name] = target
    return targets


def imports_in_file(path):
    source = path.read_text(encoding="utf-8")
    code = mask_literals(source)
    return [(line_number, match.group(1).strip("`"))
            for match in IMPORT_RE.finditer(code)
            for line_number in [code.count("\n", 0, match.start()) + 1]]


def check(root):
    issues = []
    try:
        targets = parse_targets((root / "Package.swift").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        return [f"Package.swift: {exc}"]

    production = {name: target for name, target in targets.items()
                  if target.path.startswith("Sources/")}
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

    for source in sorted((root / "Sources").rglob("*.swift")) if (root / "Sources").exists() else []:
        relative = source.relative_to(root)
        source_parts = source.relative_to(root).parts
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
        except (OSError, UnicodeError) as exc:
            issues.append(f"{relative}: cannot read source: {exc}")
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
