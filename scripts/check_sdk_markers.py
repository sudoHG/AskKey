#!/usr/bin/env python3
"""Check Release SDK markers, allowing minor differences only for Apple's test host."""

import argparse
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError(f"Invalid SDK version: {value!r}")
    return tuple((list(map(int, value.split("."))) + [0, 0])[:3])


def build_versions(output):
    markers = []
    for block in re.split(r"(?m)^\s*Load command \d+\s*$", output):
        if not re.search(r"(?m)^\s*cmd LC_BUILD_VERSION\s*$", block):
            continue
        fields = {}
        for field in ("platform", "minos", "sdk"):
            match = re.search(rf"(?m)^\s*{field}\s+(\S+)\s*$", block)
            if match is None:
                raise ValueError(f"LC_BUILD_VERSION is missing {field}")
            fields[field] = match.group(1)
        if fields["platform"] != "MACOS":
            raise ValueError(f"Expected MACOS, found {fields['platform']}")
        version(fields["minos"])
        version(fields["sdk"])
        markers.append(fields)
    if not markers:
        raise ValueError("No macOS LC_BUILD_VERSION marker found")
    architectures = re.findall(r"\(architecture [^)]+\):", output)
    if architectures and len(markers) != len(architectures):
        raise ValueError("Missing LC_BUILD_VERSION marker for an architecture")
    return markers


def selected_sdk():
    result = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True
    ).strip()
    version(result)
    return result


def test_product_binaries(directory):
    bundles = sorted(path for path in Path(directory).glob("*.xctest") if path.is_dir())
    if not bundles:
        raise ValueError(f"No XCTest bundles found in {directory}")
    binaries = []
    for bundle in bundles:
        with (bundle / "Contents/Info.plist").open("rb") as source:
            executable = plistlib.load(source).get("CFBundleExecutable")
        if (not isinstance(executable, str) or not executable or executable in {".", ".."}
                or Path(executable).name != executable):
            raise ValueError(f"Invalid CFBundleExecutable in {bundle}")
        binary = bundle / "Contents/MacOS" / executable
        if not binary.is_file():
            raise ValueError(f"Tested binary is missing: {binary}")
        binaries.append(binary)
    return binaries


def check_binary(binary, expected, test_host=False):
    if not Path(binary).is_file():
        raise ValueError(f"Tested binary is missing: {binary}")
    output = subprocess.check_output(["xcrun", "vtool", "-show-build", str(binary)], text=True)
    markers = build_versions(output)
    for marker in markers:
        policy = " (XCTest host: same SDK major required)" if test_host else ""
        print(f"SDK marker: {binary}: platform {marker['platform']} "
              f"minos {marker['minos']} sdk {marker['sdk']}; Release SDK {expected}{policy}", flush=True)
        if test_host:
            if version(marker["sdk"])[0] != version(expected)[0]:
                raise ValueError(f"SDK major mismatch for XCTest host {binary}: "
                                 f"{marker['sdk']} != Release SDK {expected}")
        elif version(marker["sdk"]) != version(expected):
            raise ValueError(f"SDK mismatch for {binary}: {marker['sdk']} != Release SDK {expected}")
    return markers


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binaries", nargs="*")
    parser.add_argument("--test-host", action="append", default=[], metavar="BINARY",
                        help="Apple XCTest host: require the Release SDK major and log full versions")
    parser.add_argument("--test-products", action="append", default=[], metavar="DIRECTORY",
                        help="Check each XCTest bundle's CFBundleExecutable, excluding debug symbols")
    args = parser.parse_args()
    if not args.binaries and not args.test_host and not args.test_products:
        parser.error("at least one binary, --test-host or --test-products is required")
    try:
        expected = selected_sdk()
        for directory in args.test_products:
            args.binaries.extend(test_product_binaries(directory))
        for binary in args.binaries:
            check_binary(binary, expected)
        for binary in args.test_host:
            check_binary(binary, expected, test_host=True)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
