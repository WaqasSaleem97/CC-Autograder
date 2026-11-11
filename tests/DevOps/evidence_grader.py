#!/usr/bin/env python3
"""Trusted, read-only screenshot grading for the DevOps build/Nexus labs.

Never import or execute anything from a student repository. Only the trusted
rubric, shared OCR helper, images, Git metadata and PDF parser are used.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal, ROUND_HALF_UP
from functools import lru_cache
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops, ImageOps, ImageStat

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from ocr_evidence import credential_exposed, prompt_matches  # noqa: E402
from resolve_screenshots import filename_key, resolve  # noqa: E402

# Pillow also raises SyntaxError during verify() for damaged image chunks,
# even when the file was recognized and opened as an image.
INVALID_IMAGE_ERRORS = (OSError, SyntaxError, ValueError, Image.DecompressionBombError)


def load_rubric(path: Path) -> dict:
    rubric = json.loads(path.read_text(encoding="utf-8"))
    checks = rubric["screenshots"]
    if len(checks) != rubric["screenshot_count"]:
        raise ValueError("Trusted screenshot count does not match the rubric")
    filenames = [check["filename"] for check in checks]
    if len(filenames) != len(set(filenames)):
        raise ValueError("Duplicate criterion filenames in trusted rubric")
    for check in checks:
        if not re.fullmatch(r"[a-z0-9_]+\.png", check["filename"]):
            raise ValueError("Unsafe filename in trusted rubric")
        if not check.get("required"):
            raise ValueError("Empty evidence requirement in trusted rubric")
        for requirement in check["required"] + check.get("forbidden", []):
            re.compile(requirement["pattern"], re.IGNORECASE | re.MULTILINE)
    return rubric


def credential_visible(text: str) -> bool:
    """Add build-tool/curl password checks to the existing secret detector."""
    if credential_exposed(text, join_url_words=False):
        return True
    if re.search(r"authorization\s*:\s*basic\s+[a-z0-9+/=]{8,}", text, re.I):
        return True
    if re.search(r"admin[.]password[\s\S]{0,200}\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b", text, re.I):
        return True
    patterns = (
        r"curl\b[^\r\n]*(?:-u|--user)[ \t]+[\"']?(?:nexus|admin)[ \t]*:[ \t]*([^\s\"']+)",
        r"\brepoPassword[ \t]*=[ \t]*([^\s]+)",
        r"<password>\s*([^<]+?)\s*</password>",
        # A hidden prompt can end with "Password:"; the next OCR line
        # often begins with an unrelated shell prompt or status message.
        r"\b(?:password|passwd)[ \t]*[:=][ \t]*[\"']?([^\s\"']+)",
    )
    for pattern in patterns:
        for match in re.finditer(pattern, text, re.IGNORECASE):
            value = match.group(1).strip("\"',; ")
            # Masked/redacted values and variable references are not secrets.
            if re.fullmatch(r"[*.•●xX]+|<[^>]*>|\[.*\]|REDACTED|HIDDEN|MASKED", value, re.I):
                continue
            if value.startswith(("$", "project.", "providers.", "System.", "process.env.")):
                continue
            if value.upper().startswith(("REPLACE_", "YOUR_")):
                continue
            return True
    return False


def evidence_problems(check: dict, text: str, username: str) -> list[str]:
    if not text.strip():
        return ["unreadable OCR"]
    if credential_visible(text):
        return ["visible password, private key or access token (value not recorded)"]
    problems = []
    if not prompt_matches(username, text):
        problems.append("registered GitHub username@ubuntu prompt not detected")
    for requirement in check["required"]:
        if not re.search(requirement["pattern"], text, re.IGNORECASE | re.MULTILINE):
            problems.append(requirement["label"] + " not detected")
    for requirement in check.get("forbidden", []):
        if re.search(requirement["pattern"], text, re.IGNORECASE | re.MULTILINE):
            problems.append(requirement["label"] + " detected")
    return problems


def contained_file(path: Path, root: Path) -> bool:
    return path.is_file() and path.resolve().is_relative_to(root.resolve())


def screenshot_directory(submission: Path) -> tuple[Path | None, str]:
    directories = sorted(
        (entry for entry in submission.iterdir()
         if entry.name.casefold() == "screenshots" and entry.is_dir()
         and entry.resolve().is_relative_to(submission)),
        key=lambda path: (path.name != "screenshots", path.name),
    )
    if len(directories) > 1:
        return None, "multiple screenshot folders differ only by capitalization"
    return (directories[0], "") if directories else (None, "missing")


def normalize_username(value: str) -> str:
    value = re.sub(r"^(?:https?://github\.com/|git@github\.com:|@)", "", value.strip(), flags=re.I)
    value = value.split("/", 1)[0].removesuffix(".git").casefold()
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?", value) or "--" in value:
        raise ValueError("A valid registered GitHub username is required")
    return value


def git_root(submission: Path) -> Path | None:
    result = subprocess.run(
        ["git", "-C", str(submission), "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=False, timeout=10,
    )
    return Path(result.stdout.strip()).resolve() if result.returncode == 0 else None


def detect_username(submission: Path) -> str:
    result = subprocess.run(
        ["git", "-C", str(submission), "remote", "get-url", "origin"],
        capture_output=True, text=True, check=False, timeout=10,
    )
    match = re.search(r"github\.com[:/]([^/]+)/", result.stdout, re.I)
    return normalize_username(match.group(1) if match else "")


@lru_cache(maxsize=4096)
def image_fingerprint(path: Path) -> tuple[str, str, int, tuple[int, int], bytes]:
    data = path.read_bytes()
    sha256 = hashlib.sha256(data).hexdigest()
    git_sha = hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
    with Image.open(path) as image:
        image.verify()
    with Image.open(path) as source:
        source = ImageOps.exif_transpose(source).convert("L")
        dimensions = source.size
        pixels = list(source.resize((9, 8)).tobytes())
        dhash = 0
        for row in range(8):
            for column in range(8):
                dhash = (dhash << 1) | (pixels[row * 9 + column] > pixels[row * 9 + column + 1])
        preview = source.resize((128, 96)).tobytes()
    return sha256, git_sha, dhash, dimensions, preview


def peer_screenshots(submission: Path, expected_names: list[str]) -> dict[str, list[Path]]:
    """Compare only sibling DevOps repositories in this workflow's collection."""
    peers = {name: [] for name in expected_names}
    repository = git_root(submission)
    if repository is None or repository.name != "DevOps":
        return peers
    relative = submission.relative_to(repository)
    if len(relative.parts) != 2 or relative.parts[0] != "Labs":
        return peers
    for owner in repository.parent.parent.iterdir():
        other = owner / "DevOps" / relative
        if other == submission or not other.is_dir() or other.is_symlink():
            continue
        directory, _ = screenshot_directory(other.resolve())
        if directory is None:
            continue
        for name, actual in resolve(directory, expected_names):
            if actual and actual != "__AMBIGUOUS__" and contained_file(Path(actual), other):
                peers[name].append(Path(actual))
    return peers


def duplicate_status(image: Path, peers: list[Path]) -> str:
    exact, _git, dhash, size, preview = image_fingerprint(image)
    near = False
    for peer in peers:
        try:
            other_exact, _other_git, other_dhash, other_size, other_preview = image_fingerprint(peer)
        except INVALID_IMAGE_ERRORS:
            continue
        if exact == other_exact:
            return "exact"
        ratio_delta = abs(size[0] / size[1] - other_size[0] / other_size[1])
        if ratio_delta < 0.02 and (dhash ^ other_dhash).bit_count() <= 2:
            difference = ImageChops.difference(
                Image.frombytes("L", (128, 96), preview),
                Image.frombytes("L", (128, 96), other_preview),
            )
            if ImageStat.Stat(difference).rms[0] / 255 < 0.025:
                near = True
    return "near" if near else ""


def run_ocr(image: Path, destination: Path) -> str:
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ocr_screenshot.py"), str(image), str(destination)],
        capture_output=True, text=True, check=False, timeout=100,
        env={**os.environ, "OMP_THREAD_LIMIT": "1"},
    )
    if result.returncode:
        raise RuntimeError("Trusted OCR helper failed; no marks were changed")
    # The shared helper also writes OCR_AUDIT_DIR for portal/manual image audit.
    text = destination.read_text(encoding="utf-8", errors="replace")
    audit_directory = os.environ.get("OCR_AUDIT_DIR", "").strip()
    if audit_directory and credential_visible(text):
        (Path(audit_directory) / destination.name).write_text(
            "[REDACTED: OCR contained a visible credential. Inspect the image privately.]\n",
            encoding="utf-8",
        )
    return text


def pdf_problem(path: Path, submission: Path) -> str:
    if not contained_file(path, submission):
        return "missing"
    with path.open("rb") as source:
        if source.read(5) != b"%PDF-":
            return "invalid or corrupt PDF"
    result = subprocess.run(
        ["pdfinfo", str(path)], capture_output=True, text=True, check=False, timeout=20,
    )
    valid = result.returncode == 0 and re.search(r"Pages:\s*[1-9]\d*", result.stdout)
    if re.search(r"Encrypted:\s*yes", result.stdout, re.I):
        valid = False
    return "" if valid else "invalid, empty or encrypted PDF"


def grade(submission: Path, total: Decimal, username: str, rubric: dict) -> dict:
    if not submission.is_dir():
        return {"score": 0, "feedback": "Required submission directory is missing"}
    submission = submission.resolve()
    checks = rubric["screenshots"]
    names = [check["filename"] for check in checks]
    directory, directory_problem = screenshot_directory(submission)
    files = dict(resolve(directory, names)) if directory else {}
    peers = peer_screenshots(submission, names)
    references = set(rubric.get("instructor_reference_git_blobs", []))
    points = total / Decimal(len(checks) + 1)
    feedback = []
    review_items = []
    review_count = 0
    passed = 0

    try:
        requested_jobs = int(os.environ.get("OCR_JOBS", "4"))
    except ValueError:
        requested_jobs = 4
    workers = max(1, min(requested_jobs, os.cpu_count() or 2, 8))
    with tempfile.TemporaryDirectory(prefix=f"devops-lab{rubric['lab']}-ocr-") as temporary:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            pending = {}
            early_problems = {}
            duplicates = {}
            for name in names:
                actual = files.get(name, "")
                if actual == "__AMBIGUOUS__":
                    early_problems[name] = "ambiguous filename (multiple case/extension matches)"
                    continue
                if not actual:
                    early_problems[name] = directory_problem or "missing"
                    continue
                image = Path(actual)
                if not contained_file(image, submission):
                    early_problems[name] = "image points outside the submission"
                    continue
                try:
                    fingerprint = image_fingerprint(image)
                except INVALID_IMAGE_ERRORS:
                    early_problems[name] = "invalid or corrupt image"
                    continue
                if fingerprint[1] in references:
                    early_problems[name] = "copied instructor reference image"
                    continue
                duplicates[name] = duplicate_status(image, peers[name])
                if duplicates[name] == "exact":
                    early_problems[name] = "exact duplicate of another student's same task"
                    continue
                pending[name] = pool.submit(run_ocr, image, Path(temporary) / (Path(name).stem + ".txt"))

            for index, check in enumerate(checks):
                name = check["filename"]
                problems = [early_problems[name]] if name in early_problems else evidence_problems(
                    check, pending[name].result(), username,
                )
                accepted = not problems
                if accepted:
                    passed += 1
                    if duplicates.get(name) == "near":
                        review_count += 1
                        message = "manual review required - visually near-duplicate same-task evidence (provisional credit)"
                    else:
                        message = "passed"
                else:
                    message = ", ".join(problems) + " (0)"
                feedback.append(f"{name}: {message}")
                review_items.append({
                    "criterion_id": f"devops-lab{rubric['lab']}-{Path(name).stem}",
                    "criterion_order": index,
                    "criterion_label": check["label"],
                    "expected_filename": name,
                    "expected_evidence": ["Registered GitHub username@ubuntu prompt"] + [
                        entry["label"] for entry in check["required"]
                    ],
                    "automatic_points": float(points) if accepted else 0,
                    "max_points": float(points),
                })

    report = rubric["solution_pdf"]
    problem = pdf_problem(submission / report, submission)
    feedback.append(f"{report}: {problem + ' (0)' if problem else 'passed'}")
    report_points = Decimal(0) if problem else points
    passed += not bool(problem)
    score = (points * passed).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    return {
        "score": float(score),
        "feedback": f"Passed {passed}/{len(checks) + 1} DevOps Lab {rubric['lab']} checks. " + "; ".join(feedback),
        "review_count": review_count,
        "review_base_points": float(report_points),
        "review_items": review_items,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rubric", type=Path)
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
        rubric = load_rubric(args.rubric)
        provided = args.github_username or os.environ.get("STUDENT_GITHUB_USERNAME", "")
        username = normalize_username(provided) if provided else detect_username(args.submission)
        result = grade(args.submission, total, username, rubric)
    except Exception as error:
        # Nonzero exit is deliberate: the workflow reports NOT GRADED for an
        # infrastructure/trusted-code error instead of assigning zero marks.
        print(f"DevOps evidence grader failed ({type(error).__name__}); no marks were changed.", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
