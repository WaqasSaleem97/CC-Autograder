#!/usr/bin/env bash
set -euo pipefail

# DevOps_F26/Labs/Lab06: 28 required screenshots + Lab6_Solution.pdf.
# Usage: bash tests/DevOps/Lab6/test.sh SUBMISSION TOTAL_MARKS [GITHUB_USERNAME]
# No live API requests or destructive Nexus cleanup/compaction tasks are run.
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$test_directory" "$@" <<'PY'
from argparse import ArgumentParser
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import shutil
import sys

lab_dir = Path(sys.argv.pop(1))
sys.path.insert(0, str(lab_dir.parent))
import evidence_grader as shared


def jar_filename(name):
    # Tesseract may insert horizontal spaces around dots or hyphens.
    spaced = "".join(
        r"[ \t]*[" + char + r"][ \t]*" if char in ".-" else re.escape(char)
        for char in name
    )
    return rf"(?<![\w.-]){spaced}(?![\w.-])"


# New Nexus file blob stores list year directories instead of vol/chap.
# Match the date-based output only directly below the read-only ls command.
DEFAULT_CONTENT_COMMAND = (
    r"^(?:[^\r\n$#]{0,180}[$#][ \t]*(?:ls|1s)|[ \t]*ls)"
    r"[ \t]+default[ \t]*/[ \t]*content/?[ \t]*\r?$"
)
DATE_BASED_CONTENT = (
    DEFAULT_CONTENT_COMMAND + r"\n(?:[ \t]*\r?\n){0,2}"
    r"[ \t]*(?:20\d{2}[ \t]+)+(?:directpath[ \t]+)?tmp[ \t]*\r?$"
)
LAST_RUN_DATE_TIME = (
    r"\bLast[ \t]+run[ \t]*:?[ \t]*(?:\r?\n[ \t]*){0,2}"
    r"(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?[ \t]+)?"
    r"(?:[A-Za-z]{3,9}[ \t]+\d{1,2},?[ \t]+20\d{2}|"
    r"\d{1,2}[ \t]+[A-Za-z]{3,9}[ \t]+20\d{2}|"
    r"20\d{2}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]20\d{2})"
    r"[ \t,]+(?:[01]?\d|2[0-3])[ \t]*:[ \t]*[0-5]\d"
    r"(?:[ \t]*:[ \t]*[0-5]\d)?\b"
)
LAST_RESULT_OK = r"\bLast[ \t]+result[ \t]*:?[ \t]*(?:\r?\n[ \t]*){0,2}Ok\b"
EMPTY_REPOSITORY = (
    r"\bThis\s+repository\s+is\s+empty"
    r"(?:[.](?=[ \t]|\r?$)|(?=[ \t]+Upload\s+components?\b)|[ \t]*\r?$)"
)


def lab6_rubric(rubric):
    checks = {item["filename"]: item for item in rubric["screenshots"]}

    def rule(filename, label, pattern, *, alternative=True):
        current = next(item for item in checks[filename]["required"] if item["label"] == label)
        current["pattern"] = rf"(?:{current['pattern']}|{pattern})" if alternative else pattern
        re.compile(current["pattern"], re.IGNORECASE | re.MULTILINE)

    rule("gradle_nexus_build.png", "Generated my-app JAR",
         jar_filename("my-app-1.0-SNAPSHOT.jar"), alternative=False)
    rule("maven_package_nexus.png", "Generated Maven JAR",
         jar_filename("java-maven-app-1.1.0-SNAPSHOT.jar"), alternative=False)
    rule("nexus_default_blob_content.png", "ls default/content", DEFAULT_CONTENT_COMMAND)
    rule("nexus_default_blob_content.png", "Real blob directory listing", DATE_BASED_CONTENT)
    rule("nexus_maven_snapshots_empty.png", "No components/assets found message", EMPTY_REPOSITORY)
    for phase in ("before", "after"):
        rule(f"nexus_blob_store_{phase}_compaction.png", "Used size column", r"\bTotal\s+Size\b")
    for task in ("cleanup", "compact"):
        filename = f"nexus_{task}_task_completed.png"
        rule(filename, "Last run timestamp", LAST_RUN_DATE_TIME)
        rule(filename, "Last result Ok", LAST_RESULT_OK)
    return rubric


def main():
    parser = ArgumentParser(description="Grade DevOps Lab 06 screenshot and PDF evidence.")
    parser.add_argument("submission", type=Path)
    parser.add_argument("total_marks")
    parser.add_argument("github_username", nargs="?")
    args = parser.parse_args()
    try:
        total = Decimal(args.total_marks)
        if not total.is_finite() or total <= 0:
            raise ValueError("TOTAL_MARKS must be a positive finite number")
        for command in ("git", "tesseract", "pdfinfo"):
            if not shutil.which(command):
                raise RuntimeError(f"Required grading tool is missing: {command}")
        rubric = lab6_rubric(shared.load_rubric(lab_dir / "criteria.json"))
        provided = args.github_username or os.environ.get("STUDENT_GITHUB_USERNAME", "")
        username = shared.normalize_username(provided) if provided else shared.detect_username(args.submission)
        result = shared.grade(args.submission, total, username, rubric)
    except Exception as error:
        print(f"DevOps Lab 06 evidence check failed ({type(error).__name__}); no marks were changed.", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
