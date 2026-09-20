#!/usr/bin/env python3
"""Resolve required screenshot stems while ignoring image extensions and case."""

from __future__ import annotations

import pathlib
import sys
from collections import defaultdict


IMAGE_EXTENSIONS = (
    ".jpeg",
    ".jpg",
    ".png",
    ".webp",
    ".bmp",
    ".tiff",
    ".tif",
    ".gif",
)


def filename_key(name: str) -> str:
    value = name.casefold().rstrip(".")
    while True:
        for extension in IMAGE_EXTENSIONS:
            if value.endswith(extension):
                value = value[: -len(extension)].rstrip(".")
                break
        else:
            return value


def resolve(directory: pathlib.Path, expected_names: list[str]) -> list[tuple[str, str]]:
    files: dict[str, list[pathlib.Path]] = defaultdict(list)
    for candidate in directory.iterdir():
        if candidate.is_file() and "\t" not in candidate.name and "\n" not in candidate.name:
            files[filename_key(candidate.name)].append(candidate.resolve())

    result: list[tuple[str, str]] = []
    for expected in expected_names:
        matches = sorted(files.get(filename_key(expected), []))
        if len(matches) == 1:
            actual = str(matches[0])
        elif len(matches) > 1:
            actual = "__AMBIGUOUS__"
        else:
            actual = ""
        result.append((expected, actual))
    return result


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "Usage: resolve_screenshots.py SCREENSHOT_DIRECTORY EXPECTED_NAME...",
            file=sys.stderr,
        )
        return 2

    directory = pathlib.Path(sys.argv[1])
    for expected, actual in resolve(directory, sys.argv[2:]):
        print(f"{expected}\t{actual}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
