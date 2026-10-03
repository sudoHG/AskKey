#!/usr/bin/env python3
"""Enforce production boundaries and keep remaining hygiene debt in a shrinking baseline."""

import argparse
from collections import Counter
import os
from pathlib import Path
import re
import subprocess
import sys

BASELINE = "scripts/hygiene-baseline.txt"
PATTERN_EXCEPTIONS = {
    "scripts/check_hygiene.py",
    "Tests/Automation/test_check_hygiene.py",
    BASELINE,
}
MULTICA_EXCEPTIONS = {"docs/features.md"}
TEST_SUPPORT = re.compile(r"E2E|Fixture|Probe|RestartProof|DebugSupport|RealUIInput")
DECLARATION = re.compile(r"\b(?:class|struct|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z_0-9]*)")
DEBUG = re.compile(r"#if\s+DEBUG\b")
DEBUG_ALLOWLIST = {
    "Sources/AskKeyAppKit/AgentClientConnector.swift",  # Isolated client configuration home.
    "Sources/AskKeyAppKit/AppPreferences.swift",  # Isolated preferences suite.
    "Sources/AskKeyAppKit/App/AppRuntimeState.swift",  # Require the packaged development run directory.
    "Sources/AskKeyBroker/BrokerProtocol.swift",  # Development broker socket namespace.
    "Sources/AskKeyBroker/DebugRunDirectory.swift",  # Validate the development run directory.
    "Sources/AskKeyVault/Keychain/IsolatedAppKeyStore.swift",  # File-backed development keys.
    "Sources/AskKeyVault/Keychain/KeychainStore.swift",  # Reject keychain I/O in isolated runs.
    "Sources/AskKeyVault/Vault.swift",  # Select the isolated development key store.
    "Sources/AskKeyVault/VaultConfiguration.swift",  # Development data and keychain namespace.
    "Sources/AskKeyHelper/main.swift",  # Resolve the development host app.
}
FIXED_CHECKS = ("test-support:", "debug:")
SWIFT_NON_CODE = re.compile(
    r'//[^\n]*|/\*|(?:\#+)?"""|(?:\#+)?"', re.MULTILINE
)


def declaration_names(text):
    """Ignore comments and string literals when looking for declared types."""
    pieces, start = [], 0
    while match := SWIFT_NON_CODE.search(text, start):
        pieces.append(text[start:match.start()])
        token, end = match.group(), match.end()
        if token == "/*":
            depth = 1
            while depth and end < len(text):
                nested = re.search(r"/\*|\*/", text[end:])
                if nested is None:
                    end = len(text)
                    break
                depth += 1 if nested.group() == "/*" else -1
                end += nested.end()
        elif not token.startswith("//"):
            hashes = len(token) - len(token.lstrip("#"))
            quote = '"""' if '"""' in token else '"'
            closing = quote + "#" * hashes
            while end < len(text):
                if text.startswith("\\" + "#" * hashes, end):
                    end += hashes + 2
                elif text.startswith(closing, end):
                    end += len(closing)
                    break
                else:
                    end += 1
        pieces.append(" ")
        start = end
    pieces.append(text[start:])
    return DECLARATION.findall("".join(pieces))


def tracked_paths(root):
    raw = subprocess.check_output(["git", "ls-files", "-z"], cwd=root)
    return sorted({os.fsdecode(path) for path in raw.split(b"\0") if path})


def tracked_bytes(path):
    # A tracked symlink stores its link text, never the contents of its target.
    if path.is_symlink():
        return os.fsencode(os.readlink(path))
    if not path.is_file():
        return None
    return path.read_bytes()


def text_content(data):
    for marker, encoding in [(b"\xff\xfe\0\0", "utf-32"), (b"\0\0\xfe\xff", "utf-32"),
                             (b"\xff\xfe", "utf-16"), (b"\xfe\xff", "utf-16")]:
        if data.startswith(marker):
            try:
                return data.decode(encoding)
            except UnicodeDecodeError:
                return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def violations(root):
    entries = set()
    for name in tracked_paths(root):
        path = root / name
        if not name.isascii():
            entries.add(f"non-ascii-name:{name}")
        data = tracked_bytes(path)
        text = text_content(data) if data is not None else None
        if (text is not None and name.startswith(("Sources/", "Tests/")) and path.suffix == ".swift"
                and path.name != "Localizable.xcstrings" and len(text.splitlines()) > 600):
            entries.add(f"size:{name}")
        if name in PATTERN_EXCEPTIONS:
            continue
        if name.startswith("Sources/"):
            if TEST_SUPPORT.search(name) or (text is not None and any(
                    TEST_SUPPORT.search(type_name) for type_name in declaration_names(text))):
                entries.add(f"test-support:{name}")
            count = len(DEBUG.findall(text)) if text is not None else 0
            if count and name not in DEBUG_ALLOWLIST:
                entries.add(f"debug:{name}:{count}")
        if name != "AGENTS.md":
            if text is not None and ("/Users/" in text or "/private/var/" in text):
                entries.add(f"local-path:{name}")
            if name not in MULTICA_EXCEPTIONS and ((data is not None and b"multica" in data.lower())
                    or (text is not None and "multica" in text.casefold())):
                entries.add(f"multica:{name}")
    return entries


def compare(current, baseline):
    recorded_debt = {entry for entry in baseline if not entry.startswith(FIXED_CHECKS)}
    new = current - recorded_debt
    fixed = (baseline - current) | {entry for entry in baseline if entry.startswith(FIXED_CHECKS)}
    return new, fixed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-baseline", action="store_true",
                        help="replace remaining hygiene debt; fixed production rules cannot be baselined")
    args = parser.parse_args()
    root = Path(subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"], text=True).strip())
    current = violations(root)
    baseline_path = root / BASELINE
    if args.write_baseline:
        forbidden = {entry for entry in current if entry.startswith(FIXED_CHECKS)}
        if forbidden:
            for entry in sorted(forbidden):
                print(f"fixed-rule violation: {entry}", file=sys.stderr)
            return 1
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text("".join(entry + "\n" for entry in sorted(current)), encoding="utf-8")
        print(f"Wrote {len(current)} baseline entries.")
        return 0
    if not baseline_path.is_file():
        print(f"Missing baseline: {BASELINE}; run with --write-baseline.", file=sys.stderr)
        return 1
    baseline = {line for line in baseline_path.read_text(encoding="utf-8").splitlines() if line}
    new, fixed = compare(current, baseline)
    for entry in sorted(new):
        print(f"new violation: {entry}")
    for entry in sorted(fixed):
        print(f"fixed, remove from baseline: {entry}")
    if new or fixed:
        return 1
    counts = Counter(entry.split(":", 1)[0] for entry in current)
    print(f"Hygiene rules match ({len(current)} baseline entries): " + ", ".join(
        f"{check}={counts.get(check, 0)}" for check in
        ["size", "test-support", "debug", "local-path", "non-ascii-name", "multica"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
