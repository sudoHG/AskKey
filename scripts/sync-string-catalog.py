#!/usr/bin/env python3
"""Compile Localizable.xcstrings into inspectable .strings files.

Do not write these next to the catalog. Xcode already compiles xcstrings into
the same Localizable.strings path, and a second copy makes the Debug/Local
bundle fail to build.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "Sources" / "AskKeyApp" / "Resources" / "Localizable.xcstrings"


def escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\"", "\\\"")


def catalog_locales(strings: dict) -> list[str]:
    locales: set[str] = set()
    for entry in strings.values():
        locales.update(entry.get("localizations", {}))
    preferred = [locale for locale in ("en", "zh-Hans") if locale in locales]
    return preferred + sorted(locale for locale in locales if locale not in preferred)


def localization_value(localization: dict) -> str | None:
    unit = localization.get("stringUnit") or {}
    if unit.get("value") is not None:
        return unit["value"]
    plural = (localization.get("variations") or {}).get("plural") or {}
    other = (plural.get("other") or {}).get("stringUnit") or {}
    if other.get("value") is not None:
        return other["value"]
    one = (plural.get("one") or {}).get("stringUnit") or {}
    return one.get("value")


def write_strings(language: str, path: Path, strings: dict) -> None:
    lines = ["/* generated from Localizable.xcstrings — do not edit by hand */", ""]
    for key, entry in strings.items():
        localization = entry.get("localizations", {}).get(language, {})
        value = localization_value(localization)
        if value is None:
            continue
        lines.append(f'"{escape(key)}" = "{escape(value)}";')
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / ".generated" / "string-catalog",
        help="Directory for generated *.lproj/Localizable.strings",
    )
    args = parser.parse_args()
    resources = CATALOG.parent
    if args.output.resolve() == resources.resolve() or resources in args.output.resolve().parents:
        print("refusing to write generated .strings into Resources next to Localizable.xcstrings", file=sys.stderr)
        raise SystemExit(2)
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    strings = catalog["strings"]
    for language in catalog_locales(strings):
        write_strings(language, args.output / f"{language}.lproj" / "Localizable.strings", strings)


if __name__ == "__main__":
    main()
