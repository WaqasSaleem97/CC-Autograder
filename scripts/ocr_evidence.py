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


def url_username_matches(expected: str, text: str) -> bool:
    """Match stronger OCR distortion only inside a GitHub URL-like line.

    Tiny browser address bars can turn ``github.com/nibasadiq`` into text such
    as ``githebcon/nbssdiq``. The wider tolerance is deliberately limited to a
    line containing a close OCR rendering of github.com or github.io, and to a
    short substring with matching endpoints. It is not used for ordinary page
    text or terminal prompts.
    """

    wanted = compact(expected)
    if len(wanted) < 6:
        return False

    targets = ("github", "githubcom", "githubio")
    protected_suffix = re.fullmatch(r"(.+?)([0-9]{2,})", wanted)
    minimum_length = max(4, len(wanted) - 2)
    maximum_length = len(wanted) + 2
    allowance = min(3, max(2, len(wanted) // 3))

    for line in unicodedata.normalize("NFKC", text).casefold().splitlines():
        tokens = [compact(token) for token in re.findall(r"[a-z0-9-]+", line)]
        tokens = [token for token in tokens if token]
        has_github_context = any(
            abs(len(token) - len(target)) <= 3
            and edit_distance(token, target) <= 4
            for token in tokens
            for target in targets
        )
        if not has_github_context:
            continue

        for token in tokens:
            if len(token) < minimum_length:
                continue
            for length in range(minimum_length, maximum_length + 1):
                for start in range(0, len(token) - length + 1):
                    candidate = token[start : start + length]
                    if candidate[0] != wanted[0] or candidate[-1] != wanted[-1]:
                        continue
                    if protected_suffix is not None:
                        if trailing_digit_ocr_match(wanted, candidate):
                            return True
                    elif edit_distance(wanted, candidate) <= allowance:
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
        ) or url_username_matches(wanted, text)
    return any(
        edit_distance(wanted, candidate) <= allowance for candidate in candidates
    ) or url_username_matches(wanted, text)


def github_url_matches(expected: str, text: str) -> bool:
    """Detect an OCR-distorted ``<username>.github.io`` browser URL.

    Some small address bars join the username and host while heavily
    distorting both, for example ``nbeasdqsthebic`` for
    ``nibasadiq.github.io``. This wider recovery is used only for URL evidence,
    never for ordinary identity matching.
    """

    if url_username_matches(expected, text):
        return True

    wanted = compact(expected)
    host = "githubio"
    if len(wanted) < 6:
        return False

    normalized = unicodedata.normalize("NFKC", text).casefold()
    # Keep OCR-preserved dots inside a candidate before compacting it. Without
    # this, a distorted `username.githebio` is split into two unrelated tokens.
    for token in re.findall(r"[a-z0-9.-]+", normalized):
        joined = compact(token)
        minimum_split = max(4, len(wanted) - 3)
        maximum_split = min(len(joined) - 5, len(wanted) + 1)
        for split in range(minimum_split, maximum_split + 1):
            seen_user, seen_host = joined[:split], joined[split:]
            if (
                abs(len(seen_host) - len(host)) <= 3
                and edit_distance(wanted, seen_user) <= 4
                and edit_distance(host, seen_host) <= 4
            ):
                return True
    return False


def repository_page_matches(expected: str, text: str) -> bool:
    """Require both the expected Pages repository and repository-page UI.

    A live portfolio also contains ``<username>.github.io``.  Repository-only
    navigation words keep a live-site screenshot from being accepted after it
    is renamed to the repository-evidence filename.  Small screenshots receive
    a narrow two-edit OCR allowance for these long, distinctive words.
    """

    if not github_url_matches(expected, text):
        return False

    context_words = (
        "branches",
        "commits",
        "releases",
        "packages",
        "contributors",
        "settings",
        "insights",
        "pullrequests",
    )
    return any(word_matches(word, text, allowance=2) for word in context_words)


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


RAW_SECRET_PATTERN = re.compile(
    r"("
    r"begin.*private\s+key|"
    r"(?:akia|asia)[0-9a-z]{16}|"
    r"ghp_[0-9a-z]{30,}|"
    r"github_pat_[0-9a-z_]{30,}|"
    r"aws_secret_access_key\s*=\s*[0-9a-z/+=]{20,}|"
    r"authorization:\s*(?:token|bearer)\s+[0-9a-z._-]{12,}|"
    r"(?:personal[\s_-]*access[\s_-]*token|access[\s_-]*token|new_token)"
    r"[\s:=]+[0-9a-z._-]{16,}"
    r")",
    flags=re.IGNORECASE,
)

COMPACT_SECRET_PATTERN = re.compile(
    r"("
    r"ghp_[0-9a-z]{30,}|"
    r"github_pat_[0-9a-z_]{30,}|"
    r"authorization:(?:token|bearer)[0-9a-z._-]{12,}|"
    r"personalaccess(?:token)?[:=][0-9a-z._-]{16,}|"
    r"access(?:token)?[:=][0-9a-z._-]{16,}|"
    r"new_token[:=][0-9a-z._-]{16,}"
    r")",
    flags=re.IGNORECASE,
)

RAW_CREDENTIAL_URL_PATTERN = re.compile(
    r"https?://[^\s@/:]+:[^\s@/<>]{6,}@",
    flags=re.IGNORECASE,
)

COMPACT_CREDENTIAL_URL_PATTERN = re.compile(
    r"https?://[^@/:]+:[^@/<>]{6,}@",
    flags=re.IGNORECASE,
)

# A low-resolution terminal screenshot can preserve a long password/token but
# lose the `@` separator immediately before the local Gitea host. Requiring an
# explicit URL, username delimiter, at least 16 credential characters, and a
# localhost marker keeps this recovery rule narrow enough to avoid treating a
# normal host:port URL as a visible credential.
COMPACT_CREDENTIAL_URL_MISSING_AT_PATTERN = re.compile(
    r"https?://[^@/:]+:[0-9a-z._-]{16,}(?:127[.]|localhost)",
    flags=re.IGNORECASE,
)

AUTH_PROMPT_PATTERN = re.compile(
    r"(?:^|\s)(?:user\s*name|username|password)\s+for\b",
    flags=re.IGNORECASE,
)

URL_IN_PROMPT_PATTERN = re.compile(
    r"https?://[^'\"‘’<>]+",
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
        if RAW_SECRET_PATTERN.search(line):
            return True
        compact_line = re.sub(r"[\t \f\v]+", "", line)
        if COMPACT_SECRET_PATTERN.search(compact_line):
            return True

        # A Git username/password prompt does not reveal the hidden password.
        # Inspect only the URL on prompt lines so the colon after the quoted
        # URL cannot combine with a later username and become a false URL
        # credential match after OCR whitespace is removed.
        if AUTH_PROMPT_PATTERN.search(line):
            for url in URL_IN_PROMPT_PATTERN.findall(line):
                compact_url = re.sub(r"[\t \f\v]+", "", url)
                if RAW_CREDENTIAL_URL_PATTERN.search(url) or (
                    COMPACT_CREDENTIAL_URL_PATTERN.search(compact_url)
                ) or (
                    COMPACT_CREDENTIAL_URL_MISSING_AT_PATTERN.search(compact_url)
                ):
                    return True
            continue

        if RAW_CREDENTIAL_URL_PATTERN.search(line):
            return True
        if COMPACT_CREDENTIAL_URL_PATTERN.search(compact_line):
            return True
        if COMPACT_CREDENTIAL_URL_MISSING_AT_PATTERN.search(compact_line):
            return True
    return False


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "credential":
        text = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
        return 0 if credential_exposed(text) else 1

    if len(sys.argv) != 4 or sys.argv[1] not in {
        "username",
        "prompt",
        "url",
        "repository",
    }:
        print(
            "Usage: ocr_evidence.py "
            "{username|prompt|url|repository} EXPECTED_USERNAME OCR_TEXT_FILE\n"
            "       ocr_evidence.py credential OCR_TEXT_FILE",
            file=sys.stderr,
        )
        return 2

    mode, expected, source = sys.argv[1:]
    text = Path(source).read_text(encoding="utf-8", errors="replace")
    if mode == "username":
        matched = username_matches(expected, text)
    elif mode == "prompt":
        matched = prompt_matches(expected, text)
    elif mode == "url":
        matched = github_url_matches(expected, text)
    else:
        matched = repository_page_matches(expected, text)
    return 0 if matched else 1


if __name__ == "__main__":
    raise SystemExit(main())
