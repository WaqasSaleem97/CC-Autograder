#!/usr/bin/env python3
"""Identity matching helpers for noisy screenshot OCR."""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path


def compact(value: str) -> str:
    return "".join(character for character in value.casefold() if character.isalnum())


def edit_distance(left: str, right: str) -> int:
    previous = list(range(len(right) + 1))
    for left_index, left_character in enumerate(left, 1):
        current = [left_index]
        for right_index, right_character in enumerate(right, 1):
            current.append(
                min(
                    current[-1] + 1,
                    previous[right_index] + 1,
                    previous[right_index - 1]
                    + (left_character != right_character),
                )
            )
        previous = current
    return previous[-1]


def allowed_ocr_edits(length: int) -> int:
    if length < 6:
        return 0
    if length < 10:
        return 1
    if length < 16:
        return 2
    return 3


def candidate_tokens(text: str, expected_length: int, allowance: int) -> set[str]:
    result: set[str] = set()
    for raw_line in unicodedata.normalize("NFKC", text).casefold().splitlines():
        tokens = [compact(token) for token in re.findall(r"[a-z0-9-]+", raw_line)]
        tokens = [token for token in tokens if token]
        for index in range(len(tokens)):
            for width in (1, 2, 3):
                candidate = "".join(tokens[index : index + width])
                if expected_length - allowance <= len(candidate) <= expected_length + allowance:
                    result.add(candidate)
    return result


def username_matches(expected: str, text: str) -> bool:
    wanted = compact(expected)
    if not wanted:
        return False

    normalized = compact(text)
    if wanted in normalized:
        return True

    allowance = allowed_ocr_edits(len(wanted))
    if allowance == 0:
        return False
    return any(
        edit_distance(wanted, candidate) <= allowance
        for candidate in candidate_tokens(text, len(wanted), allowance)
    )


def word_matches(expected: str, text: str, allowance: int = 1) -> bool:
    wanted = compact(expected)
    for token in re.findall(r"[a-z0-9]+", text.casefold()):
        candidate = compact(token)
        if abs(len(wanted) - len(candidate)) <= allowance and edit_distance(
            wanted, candidate
        ) <= allowance:
            return True
    return False


def prompt_matches(expected: str, text: str) -> bool:
    lines = unicodedata.normalize("NFKC", text).casefold().splitlines()
    for index in range(len(lines)):
        # OCR frequently puts the username, @, and hostname on adjacent lines.
        window = " ".join(lines[index : index + 5])
        if username_matches(expected, window) and word_matches("ubuntu", window):
            return True
    return False


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in {"username", "prompt"}:
        print(
            "Usage: ocr_evidence.py {username|prompt} EXPECTED_USERNAME OCR_TEXT_FILE",
            file=sys.stderr,
        )
        return 2

    mode, expected, source = sys.argv[1:]
    text = Path(source).read_text(encoding="utf-8", errors="replace")
    matched = (
        username_matches(expected, text)
        if mode == "username"
        else prompt_matches(expected, text)
    )
    return 0 if matched else 1


if __name__ == "__main__":
    raise SystemExit(main())
