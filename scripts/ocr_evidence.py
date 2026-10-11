#!/usr/bin/env python3
"""Identity matching helpers for noisy screenshot OCR."""

from __future__ import annotations

import re
import sys
import unicodedata
from pathlib import Path


def compact(value: str) -> str:
    # GitHub usernames are ASCII. Decomposing OCR accents (for example, an
    # accented ``e`` produced from a terminal digit) keeps harmless OCR noise
    # from becoming a completely different character.
    normalized = unicodedata.normalize("NFKD", value.casefold())
    return "".join(
        character
        for character in normalized
        if character.isascii() and character.isalnum()
    )


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
    if length < 13:
        return 2
    return 3


def candidate_tokens(text: str, expected_length: int, allowance: int) -> set[str]:
    result: set[str] = set()
    # OCR can split one username at a line boundary (for example, inside a
    # browser URL). Treat adjacent tokens across lines the same as adjacent
    # tokens on one line while keeping the matching window deliberately small.
    normalized = unicodedata.normalize("NFKC", text).casefold()
    tokens = [compact(token) for token in re.findall(r"[a-z0-9-]+", normalized)]
    tokens = [token for token in tokens if token]
    for index in range(len(tokens)):
        for width in (1, 2, 3):
            candidate = "".join(tokens[index : index + width])
            if expected_length - allowance <= len(candidate) <= expected_length + allowance:
                result.add(candidate)
    return result


def trailing_digit_ocr_match(expected: str, candidate: str) -> bool:
    """Match a numeric username suffix only when OCR saw a suffix too.

    Terminal OCR commonly turns a suffix such as ``050`` into letters such as
    ``eSe``. We accept that shape when the stable alphabetic prefix still
    matches closely, but do not accept a prompt that omits the suffix entirely.
    """

    match = re.fullmatch(r"(.+?)([0-9]{2,})", expected)
    if match is None:
        return False

    expected_base, expected_suffix = match.groups()
    if len(expected_base) < 6:
        return False

    for base_length in range(max(1, len(expected_base) - 1), len(expected_base) + 2):
        seen_base = candidate[:base_length]
        seen_suffix = candidate[base_length:]
        if (
            len(expected_suffix) - 1
            <= len(seen_suffix)
            <= len(expected_suffix) + 1
            and edit_distance(expected_base, seen_base) <= 1
        ):
            return True
    return False


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
    candidates = candidate_tokens(text, len(wanted), allowance)
    protected_suffix = re.fullmatch(r"(.+?)([0-9]{2,})", wanted)
    if protected_suffix and len(protected_suffix.group(1)) >= 6:
        return any(
            trailing_digit_ocr_match(wanted, candidate)
            for candidate in candidates
        )
    return any(edit_distance(wanted, candidate) <= allowance for candidate in candidates)


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
    normalized = unicodedata.normalize("NFKC", text).casefold()
    lines = normalized.splitlines()
    for index in range(len(lines)):
        # OCR frequently puts the username, @, and hostname on adjacent lines.
        window = " ".join(lines[index : index + 5])
        if username_matches(expected, window) and word_matches("ubuntu", window):
            return True

    # OCR sometimes reads ``@`` as ``g`` and joins the prompt into one token,
    # for example ``taneeszahragubuntu``. Split only tokens ending in the exact
    # Ubuntu hostname, then apply the same conservative username matcher.
    for token in re.findall(r"[a-z0-9-]+", normalized):
        compact_token = compact(token)
        if compact_token.endswith("ubuntu") and username_matches(
            expected, compact_token[: -len("ubuntu")]
        ):
            return True
    return False


RAW_CREDENTIAL_PATTERN = re.compile(
    r"("
    r"begin.*private\s+key|"
    r"(?:akia|asia)[0-9a-z]{16}|"
    r"ghp_[0-9a-z]{30,}|"
    r"github_pat_[0-9a-z_]{30,}|"
    r"aws_secret_access_key\s*=\s*[0-9a-z/+=]{20,}|"
    r"https?://[^\s@/:]+:[^\s@/<>]{6,}@|"
    r"authorization:\s*(?:token|bearer)\s+[0-9a-z._-]{12,}|"
    r"(?:personal[\s_-]*access[\s_-]*token|access[\s_-]*token|new_token)"
    r"[\s:=]+[0-9a-z._-]{16,}"
    r")",
    flags=re.IGNORECASE,
)

COMPACT_CREDENTIAL_PATTERN = re.compile(
    r"("
    r"https?://[^@/:]+:[^@/<>]{6,}@|"
    r"ghp_[0-9a-z]{30,}|"
    r"github_pat_[0-9a-z_]{30,}|"
    r"authorization:(?:token|bearer)[0-9a-z._-]{12,}|"
    r"personalaccess(?:token)?[:=][0-9a-z._-]{16,}|"
    r"access(?:token)?[:=][0-9a-z._-]{16,}|"
    r"new_token[:=][0-9a-z._-]{16,}"
    r")",
    flags=re.IGNORECASE,
)


def credential_exposed(text: str) -> bool:
    """Detect visible secrets without joining unrelated OCR lines.

    Horizontal spacing is ignored because OCR often inserts spaces around URL
    punctuation. Line boundaries remain significant so a normal URL on one
    line cannot combine with a later ``student@ubuntu`` prompt and look like a
    password-bearing URL.
    """

    normalized = unicodedata.normalize("NFKC", text)
    for line in normalized.splitlines():
        if RAW_CREDENTIAL_PATTERN.search(line):
            return True
        compact_line = re.sub(r"[\t \f\v]+", "", line)
        if COMPACT_CREDENTIAL_PATTERN.search(compact_line):
            return True
    return False


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "credential":
        text = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
        return 0 if credential_exposed(text) else 1

    if len(sys.argv) != 4 or sys.argv[1] not in {"username", "prompt"}:
        print(
            "Usage: ocr_evidence.py {username|prompt} EXPECTED_USERNAME OCR_TEXT_FILE\n"
            "       ocr_evidence.py credential OCR_TEXT_FILE",
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
