#!/usr/bin/env bash
set -u

# Grade Assignment 01 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Assignment01/test.sh \
#     work/submissions/Student/CC/Assignments/Assignment01 \
#     10
#
# Manual example:
#   bash tests/Assignment01/test.sh \
#     /path/to/CC/Assignments/Assignment01 \
#     10 \
#     waqassaleem97

json_error() {
  node -e '
    console.log(JSON.stringify({
      score: 0,
      feedback: process.argv[1]
    }))
  ' "$1"
  exit 0
}

if [[ $# -lt 2 ]]; then
  printf '%s\n' '{"score":0,"feedback":"Usage: test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]"}'
  exit 0
fi

submission_input="$1"
total_marks="$2"

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut sort nproc; do
  command -v "$command" >/dev/null 2>&1 || {
    if command -v node >/dev/null 2>&1; then
      json_error "Required grading tool is missing: $command"
    fi
    printf '%s\n' "{\"score\":0,\"feedback\":\"Required grading tool is missing: $command\"}"
    exit 0
  }
done

python3 - <<'PY' >/dev/null 2>&1 || json_error "Python Pillow is required for image validation."
from PIL import Image
PY

if ! python3 - "$total_marks" <<'PY' >/dev/null 2>&1
from decimal import Decimal
import sys

value = Decimal(sys.argv[1])
assert value > 0 and value.is_finite()
PY
then
  json_error "TOTAL_MARKS must be a positive number."
fi

if [[ ! -d "$submission_input" ]]; then
  json_error "Submission directory does not exist: $submission_input"
fi

submission_dir="$(realpath "$submission_input")"
screenshots_dir="$submission_dir/screenshots"

if [[ ! -d "$screenshots_dir" ]]; then
  json_error "Required directory is missing: Assignments/Assignment01/screenshots"
fi

# Username priority:
# 1. Third command-line argument
# 2. STUDENT_GITHUB_USERNAME environment variable
# 3. Owner name from the cloned repository origin URL
provided_username="${3:-${STUDENT_GITHUB_USERNAME:-}}"

if [[ -n "$provided_username" ]]; then
  github_username="$provided_username"
else
  remote_url="$(git -C "$submission_dir" remote get-url origin 2>/dev/null || true)"
  github_username="$(
    printf '%s' "$remote_url" |
      sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#; s#\.git$##'
  )"
fi

github_username="$(
  printf '%s' "$github_username" |
    sed -E \
      -e 's#^https?://([^/]+@)?github\.com/##I' \
      -e 's#^git@github\.com:##I' \
      -e 's#/.*$##' \
      -e 's#^@##' \
      -e 's#\.git$##I' \
      -e 's/^[[:space:]]+//' \
      -e 's/[[:space:]]+$//'
)"

if [[ ! "$github_username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] || [[ "$github_username" == *--* ]]; then
  json_error "A valid GitHub username was not provided and could not be detected from the repository origin."
fi

normalized_username="$(printf '%s' "$github_username" | tr '[:upper:]' '[:lower:]')"
escaped_username="$(printf '%s' "$normalized_username" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none      - no username requirement
#   username  - the student's GitHub username must appear
#   codespace - username or clear GitHub Codespaces context must appear
#
# Every ;; separated expression is required. Alternatives inside one expression
# use normal extended-regex parentheses and |.
readarray -t criteria <<'EOF'
task1_gitea_running.png|none|gitea;;(sign[[:space:]]+in|register|dashboard|explore|repositories|home);;(app[.]github[.]dev|codespace|3000)
task1_gitea_repository.png|none|(gitea|repositories);;readme;;20[0-9]{2}.*[0-9]{1,3}
task1_gitea_push.png|username|git[[:space:]]+(pull|push);;gitea;;(already[[:space:]]+up[[:space:]]+to[[:space:]]+date|fast-forward|from[[:space:]]+https|new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|main|master)
task2_github_push.png|codespace|git[[:space:]]+push;;(github|github[.]com);;(main|master|new[[:space:]]+branch|everything[[:space:]]+up-to-date|set[[:space:]]+up[[:space:]]+to[[:space:]]+track)
task2_remotes.png|codespace|git[[:space:]]+remote[[:space:]]+-v;;gitea;;github;;fetch;;push
task2_github_repository.png|username|(assignment[[:space:]_-]*1|assignment01);;readme;;github
task3_lfs_setup.png|codespace|git[[:space:]]+lfs[[:space:]]+version;;git[[:space:]]+lfs[[:space:]]+track;;gitattributes
task3_lfs_files.png|codespace|git[[:space:]]+lfs[[:space:]]+ls-files
task3_lfs_push.png|codespace|git[[:space:]]+push;;(uploading[[:space:]]+lfs[[:space:]]+objects|lfs[[:space:]]+objects|github);;(100%|3/3|everything[[:space:]]+up-to-date|main|master)
task4_pages_repository.png|username|github[.]io;;(index[.]html|html);;(css|style|portfolio|cv)
task4_pages_deployment.png|username|github[[:space:]]+pages;;(deployed|deployment|published|active|success|your[[:space:]]+site[[:space:]]+is[[:space:]]+live);;github[.]io
task4_portfolio_live.png|username|github[.]io;;(portfolio|curriculum[[:space:]]+vitae|cv|about[[:space:]]+me|education|skills|experience|projects)
EOF

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use all logical CPUs available on
# the runner. OCR_JOBS may request fewer workers but cannot exceed the available
# CPUs or the safety cap of 8.
ocr_dir="$(mktemp -d "/tmp/assignment01-ocr-${normalized_username}.XXXXXX")"
cleanup() {
  rm -rf -- "$ocr_dir"
}
trap cleanup EXIT

available_cpus="$(nproc 2>/dev/null || true)"
if [[ ! "$available_cpus" =~ ^[1-9][0-9]*$ ]]; then
  available_cpus=2
fi

ocr_jobs="${OCR_JOBS:-$available_cpus}"
if [[ ! "$ocr_jobs" =~ ^[1-9][0-9]*$ ]]; then
  ocr_jobs="$available_cpus"
fi
if (( ocr_jobs > available_cpus )); then
  ocr_jobs="$available_cpus"
fi
if (( ocr_jobs > 8 )); then
  ocr_jobs=8
fi

printf '%s\n' "${criteria[@]}" |
  cut -d'|' -f1 |
  while IFS= read -r filename; do
    [[ -f "$screenshots_dir/$filename" ]] && printf '%s\n' "$filename"
  done |
  xargs -r -P "$ocr_jobs" -I '{}' \
    bash -c '
      source_image="$1/$2"
      output_base="$3/${2%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _ "$screenshots_dir" '{}' "$ocr_dir"

# Build one exact-duplicate index for screenshots with the same filename across
# every student selected in this workflow. Both students receive zero for a
# duplicated task screenshot. Images from different tasks are not compared.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/assignment01-duplicate-images-${duplicate_key}.tsv"

  if [[ ! -f "$duplicate_index" ]]; then
    python3 - "$submissions_root" "$relative_screenshots" "$duplicate_index" <<'PY'
import hashlib
import itertools
import pathlib
import sys
from collections import defaultdict

root = pathlib.Path(sys.argv[1]).resolve()
relative = pathlib.PurePosixPath(sys.argv[2])
output = pathlib.Path(sys.argv[3])
groups = defaultdict(list)

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file() and image.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            groups[image.name.lower()].append(image.resolve())

duplicates = {}
for paths in groups.values():
    fingerprints = {}
    for image in paths:
        try:
            fingerprints[image] = hashlib.sha256(image.read_bytes()).hexdigest()
        except OSError:
            continue

    for left, right in itertools.combinations(fingerprints, 2):
        if fingerprints[left] == fingerprints[right]:
            reason = "exact duplicate of another student's same task"
            duplicates[left] = reason
            duplicates[right] = reason

output.write_text(
    "".join(f"{path}\t{reason}\n" for path, reason in sorted(duplicates.items())),
    encoding="utf-8",
)
PY
  fi
fi

passed=0
feedback=()

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  remainder="${rule#*|}"
  identity_flag="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  image="$screenshots_dir/$filename"

  if [[ ! -f "$image" ]]; then
    feedback+=("$filename: missing (0)")
    continue
  fi

  # Verify that the submitted file is a decodable image. No minimum dimensions
  # or minimum file-size rule is applied.
  if ! python3 - "$image" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys

with Image.open(sys.argv[1]) as image:
    image.verify()
PY
  then
    feedback+=("$filename: invalid or corrupt image (0)")
    continue
  fi

  canonical_image="$(realpath "$image")"
  if [[ -n "$duplicate_index" && -s "$duplicate_index" ]]; then
    duplicate_reason="$(awk -F '\t' -v path="$canonical_image" '$1 == path {print $2; exit}' "$duplicate_index")"
    if [[ -n "$duplicate_reason" ]]; then
      feedback+=("$filename: $duplicate_reason (0)")
      continue
    fi
  fi

  ocr_file="$ocr_dir/${filename%.*}.txt"
  ocr_text=""
  if [[ -f "$ocr_file" ]]; then
    ocr_text="$(tr '[:upper:]' '[:lower:]' < "$ocr_file")"
  fi

  if [[ -z "${ocr_text//[[:space:]]/}" ]]; then
    feedback+=("$filename: unreadable OCR (0)")
    continue
  fi

  # Reject exposed credentials and private-key bodies. A redacted value is
  # acceptable; a visible PAT, GitHub token, AWS key, password embedded in a
  # URL, Authorization token, or PEM private key is not. Tesseract sometimes
  # inserts spaces around URL punctuation, so also inspect whitespace-normalized
  # OCR text.
  compact_ocr_text="$(printf '%s' "$ocr_text" | tr -d '[:space:]')"
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,}|https?://[^[:space:]@/:]+:[^[:space:]@/<>]{6,}@|authorization:[[:space:]]*(token|bearer)[[:space:]]+[0-9a-z._-]{12,}|(personal[[:space:]_-]*access[[:space:]_-]*token|access[[:space:]_-]*token|new_token)[[:space:]:=]+[0-9a-z._-]{16,})' <<<"$ocr_text" || \
     grep -Eqi -- '(https?://[^@/:]+:[^@/<>]{6,}@|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|authorization:(token|bearer)[0-9a-z._-]{12,}|personalaccess(token)?[:=][0-9a-z._-]{16,}|access(token)?[:=][0-9a-z._-]{16,}|new_token[:=][0-9a-z._-]{16,})' <<<"$compact_ocr_text"; then
    feedback+=("$filename: exposed credential, token, password, or private-key material is visible (0)")
    continue
  fi

  identity_pattern=""
  identity_message=""
  case "$identity_flag" in
    username)
      identity_pattern="(^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)"
      identity_message="the student's GitHub username was not clearly detected"
      ;;
    codespace)
      identity_pattern="((^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)|/workspaces/|codespaces?|app[.]github[.]dev)"
      identity_message="the student's GitHub username or Codespaces context was not clearly detected"
      ;;
  esac

  if [[ -n "$identity_pattern" ]] && ! grep -Eqi "$identity_pattern" <<<"$ocr_text"; then
    feedback+=("$filename: $identity_message (0)")
    continue
  fi

  evidence_ok=true
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    if ! grep -Eqi -- "$evidence_pattern" <<<"$ocr_text"; then
      evidence_ok=false
      break
    fi
  done < <(printf '%s' "$evidence_groups" | sed 's/;;/\n/g')

  if [[ "$evidence_ok" != true ]]; then
    feedback+=("$filename: required task evidence was not detected (0)")
    continue
  fi

  # The Assignment requires three LFS-tracked files. Tesseract normally reads
  # each `git lfs ls-files` entry as an abbreviated object ID followed by its
  # filename. Accept explicit 3/3 output as an alternative.
  if [[ "$filename" == "task3_lfs_files.png" ]]; then
    lfs_entry_count="$(grep -Eci '^[[:space:]]*[0-9a-z]{6,}[[:space:]]+[*-]?[[:space:]]*[^[:space:]]+[.][a-z0-9]{1,8}' <<<"$ocr_text" || true)"
    if (( lfs_entry_count < 3 )) && ! grep -Eqi '3[[:space:]]*/[[:space:]]*3' <<<"$ocr_text"; then
      feedback+=("$filename: three LFS-tracked file entries were not clearly detected (0)")
      continue
    fi
  fi

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

# Every required screenshot has equal weight. Scale the passed checks to the
# TOTAL_MARKS value supplied by the workflow.
score="$(python3 - "$passed" "$required" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

passed, required, total = map(Decimal, sys.argv[1:])
value = (passed / required * total).quantize(
    Decimal("0.01"),
    rounding=ROUND_HALF_UP,
)
print(value)
PY
)"

summary="Passed $passed/$required Assignment 01 required screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
