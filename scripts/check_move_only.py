#!/usr/bin/env python3
"""Compare Swift line multisets with a base ref to verify move-only refactors."""

import argparse
from collections import Counter, defaultdict, deque
from dataclasses import dataclass
from pathlib import Path
import re
import subprocess
import sys

ACCESS = re.compile(r"\b(?:private|fileprivate|internal|package|public)\b[ \t]*")
STRING_START = re.compile(r'\#*(?:"""|")')
IMPORT = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*import\b")
MODIFIERS = (
    r"^(?P<modifiers>(?:(?:private|fileprivate|internal|package|public)(?:\(set\))?\s+|"
    r"(?:static|class|final|open|override|required|convenience|mutating|nonmutating|"
    r"nonisolated|isolated|distributed|indirect|lazy|weak|unowned|borrowing|consuming)"
    r"(?:\([^)]*\))?\s+|@\w+(?:\.\w+)*(?:\([^)]*\))?\s+)*)"
)
DECLARATION = re.compile(
    MODIFIERS +
    r"(?:extension|struct|class|enum|protocol|actor|func|var|let)\s+\S"
)
ACCESS_DECLARATION = re.compile(
    MODIFIERS + r"(?:extension|struct|class|enum|protocol|actor|func|var|let|"
    r"init|deinit|subscript|typealias|associatedtype|case)\b"
)


@dataclass(frozen=True)
class Line:
    path: str
    number: int
    text: str
    code: str

    def access_key(self):
        """Remove access tokens from code, preserving strings and comments exactly."""
        header = ACCESS_DECLARATION.match(self.code.strip())
        leading = len(self.code) - len(self.code.lstrip())
        if header is not None:
            end = leading + header.end("modifiers")
        elif ACCESS.fullmatch(self.code.strip()):
            end = len(self.code)
        else:
            return self.text
        pieces, start = [], 0
        for match in ACCESS.finditer(self.code, 0, end):
            pieces.append(self.text[start:match.start()])
            start = match.end()
        pieces.append(self.text[start:])
        return "".join(pieces).strip()

    def is_header(self):
        code = self.code.strip()
        if not DECLARATION.match(code) or ";" in code:
            return False
        # A declaration with an inline body also adds executable code.
        _, brace, body = code.partition("{")
        return not brace or not body.strip("{} \t")


def normalized_lines(path, text):
    """Ignore comment-only lines without discarding text inside Swift literals."""
    result = []
    depth, closing, escape = 0, None, None
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        code = [" "] * len(line)
        literal = closing is not None
        offset = 0
        while offset < len(line):
            if depth:
                if line.startswith("/*", offset):
                    depth += 1
                    offset += 2
                elif line.startswith("*/", offset):
                    depth -= 1
                    offset += 2
                else:
                    offset += 1
            elif closing:
                if line.startswith(escape, offset):
                    offset += len(escape) + 1
                elif line.startswith(closing, offset):
                    offset += len(closing)
                    closing = None
                else:
                    offset += 1
            elif line.startswith("//", offset):
                break
            elif line.startswith("/*", offset):
                depth = 1
                offset += 2
            elif match := STRING_START.match(line, offset):
                token = match.group()
                hashes = len(token) - len(token.lstrip("#"))
                closing = token[hashes:] + "#" * hashes
                escape = "\\" + "#" * hashes
                literal = True
                offset = match.end()
            else:
                code[offset] = line[offset]
                offset += 1
        masked = "".join(code)
        if not line or (not literal and (not masked.strip() or
                not line.strip("{} \t") or IMPORT.match(masked.strip()))):
            continue
        result.append(Line(path, number, line, masked))
    return result


def unmatched(lines, other):
    """Cancel matching occurrences, preserving locations of unmatched lines."""
    available = Counter(line.text for line in other)
    result = []
    for line in lines:
        if available[line.text]:
            available[line.text] -= 1
        else:
            result.append(line)
    return result


def compare(before, after):
    removed, added = [], []
    for path in sorted(before.keys() | after.keys()):
        old, new = before.get(path, []), after.get(path, [])
        removed.extend(unmatched(old, new))
        added.extend(unmatched(new, old))
    missing, extra = unmatched(removed, added), unmatched(added, removed)
    candidates = defaultdict(deque)
    for index, line in enumerate(extra):
        candidates[line.access_key()].append(index)
    access, unpaired, paired = [], [], set()
    for line in missing:
        matches = candidates[line.access_key()]
        if matches:
            index = matches.popleft()
            paired.add(index)
            access.append((line, extra[index]))
        else:
            unpaired.append(line)
    headers, other = [], []
    for index, line in enumerate(extra):
        if index not in paired:
            (headers if line.is_header() else other).append(line)
    return unpaired, headers, access, other


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.PIPE)


def snapshots(root, base, paths):
    base = git(root, "rev-parse", "--verify", base + "^{commit}").decode().strip()
    old_names = set(git(root, "ls-tree", "-r", "--name-only", "-z", base, "--", *paths).split(b"\0"))
    new_names = set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
                        "--", *paths).split(b"\0"))
    before, after = {}, {}
    for name in sorted(old_names | new_names):
        if not name or not name.endswith(b".swift"):
            continue
        path = name.decode("utf-8")
        if name in old_names:
            before[path] = normalized_lines(path, git(root, "show", base + ":" + path).decode("utf-8"))
        current = root / path
        if current.is_symlink():
            raise ValueError(f"Swift symlinks are not supported: {path}")
        if current.is_file():
            after[path] = normalized_lines(path, current.read_text(encoding="utf-8"))
    return before, after


def location(line):
    return f"{line.path}:{line.number}: {line.text}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base_ref", help="base commit or ref to compare with the working tree")
    parser.add_argument("paths", nargs="*", default=["Sources", "Tests"],
                        help="repository-relative paths (default: Sources Tests)")
    args = parser.parse_args()
    try:
        root = Path(git(None, "rev-parse", "--show-toplevel").decode().strip())
        before, after = snapshots(root, args.base_ref, args.paths)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        detail = error.stderr.decode(errors="replace").strip() if isinstance(
            error, subprocess.CalledProcessError) else str(error)
        print(f"Move-only check error: {detail}", file=sys.stderr)
        return 2
    missing, headers, access, other = compare(before, after)
    for label, lines in [("Missing removed lines", missing), ("Declaration headers", headers),
                         ("Access-modifier-only differences", access), ("Other added lines", other)]:
        if lines:
            print(f"{label} ({len(lines)}):")
            for line in lines:
                if label == "Access-modifier-only differences":
                    print(f"  {location(line[0])}\n    -> {location(line[1])}")
                else:
                    print(f"  {location(line)}")
    failed = bool(missing or other)
    print(f"Move-only check: {'FAIL' if failed else 'PASS'}; "
          f"missing={len(missing)}, declaration headers={len(headers)}, "
          f"access-only={len(access)}, other={len(other)}.")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
