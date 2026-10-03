#!/usr/bin/env bash
set -u

# Grade Assignment 01 required files and screenshot evidence.
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
#   ubuntu    - the case-insensitive <github-username>@ubuntu prompt must appear
#
# Every ;; separated expression is required. Alternatives inside one expression
# use normal extended-regex parentheses and |.
readarray -t criteria <<'EOF'
task1_gitea_running.png|ubuntu|docker[[:space:]]+compose[[:space:]]+ps;;gitea;;(postgres|gitea_db|gitea[[:space:]_-]*db);;(up|running|healthy);;(gitea[[:space:]]+http[[:space:]]+status|http[[:space:]]+status).*200
task1_gitea_repository.png|none|(gitea|repositories);;(assignment[[:space:]_-]*0?1);;readme;;20[0-9]{2}.*[0-9]{1,3}
task1_gitea_push.png|ubuntu|git[[:space:]]+push([[:space:]]+-u)?[[:space:]]+gitea[[:space:]]+main;;gitea;;main;;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_github_push.png|ubuntu|git[[:space:]]+push([[:space:]]+-u)?[[:space:]]+github[[:space:]]+main;;(github|github[.]com);;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_remotes.png|ubuntu|git[[:space:]]+remote[[:space:]]+-v;;gitea;;(127[.]0[.]0[.]1|localhost);;github;;github[.]com;;fetch;;push
task2_github_repository.png|username|(assignment[[:space:]_-]*0?1);;readme;;github;;public;;20[0-9]{2}.*[0-9]{1,3}
task3_lfs_setup.png|ubuntu|(git[[:space:]]+lfs[[:space:]]+install|git[[:space:]]+lfs[[:space:]]+initialized);;git[[:space:]]+lfs[[:space:]]+version;;git[[:space:]]+lfs[[:space:]]+track;;gitattributes;;bin
task3_lfs_files.png|ubuntu|git[[:space:]]+lfs[[:space:]]+ls-files;;[.]bin
task3_lfs_push.png|ubuntu|git[[:space:]]+push[[:space:]]+github[[:space:]]+main;;(uploading[[:space:]]+lfs[[:space:]]+objects|lfs[[:space:]]+objects);;(100%|3[[:space:]]*/[[:space:]]*3);;(github|github[.]com)
task4_pages_repository.png|username|github[.]io;;index[.]html;;styles[.]css;;public
task4_pages_deployment.png|username|github[[:space:]]+pages;;(deployed|deployment|published|active|success|your[[:space:]]+site[[:space:]]+is[[:space:]]+live);;github[.]io
task4_portfolio_live.png|username|github[.]io;;(portfolio|curriculum[[:space:]]+vitae|cv|about[[:space:]]+me|education|skills|projects)
EOF

required=${#criteria[@]}

# Required deliverables account for 10% of the score. Filenames are matched
# case-insensitively, but each file must be a valid non-empty file of its type.
readarray -t artifact_criteria <<'EOF'
Assignment01.md|markdown
Assignment01_Solution.docx|docx
Assignment01_Solution.pdf|pdf
EOF
artifact_required=${#artifact_criteria[@]}

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

validate_artifact() {
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import pathlib
import sys
import zipfile

path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
if not path.is_file() or path.stat().st_size == 0:
    raise SystemExit(1)

if kind == "markdown":
    if not path.read_text(encoding="utf-8", errors="ignore").strip():
        raise SystemExit(1)
elif kind == "docx":
    if not zipfile.is_zipfile(path):
        raise SystemExit(1)
    with zipfile.ZipFile(path) as document:
        if "word/document.xml" not in document.namelist():
            raise SystemExit(1)
elif kind == "pdf":
    with path.open("rb") as document:
        if document.read(5) != b"%PDF-":
            raise SystemExit(1)
else:
    raise SystemExit(1)
PY
}

artifact_passed=0
artifact_feedback=()
for artifact_rule in "${artifact_criteria[@]}"; do
  artifact_name="${artifact_rule%%|*}"
  artifact_kind="${artifact_rule#*|}"
  artifact_path="$(find "$submission_dir" -maxdepth 1 -type f -iname "$artifact_name" -print -quit)"

  if [[ -z "$artifact_path" ]]; then
    artifact_feedback+=("$artifact_name: missing required assignment file (0)")
  elif ! validate_artifact "$artifact_path" "$artifact_kind"; then
    artifact_feedback+=("$artifact_name: invalid, empty, or unreadable assignment file (0)")
  else
    artifact_passed=$((artifact_passed + 1))
    artifact_feedback+=("$artifact_name: passed")
  fi
done

passed=0
feedback=("${artifact_feedback[@]}")

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
    ubuntu)
      identity_pattern="(^|[^[:alnum:]-])${escaped_username}[[:space:]]*@[[:space:]]*ubuntu([^[:alnum:]_.-]|$)"
      identity_message="the required <github-username>@ubuntu prompt was not clearly detected"
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

  # The Assignment requires three .bin files and each file must be larger than
  # 100 MiB. `git lfs ls-files --size` normally prints one object, filename,
  # and human-readable size per line.
  if [[ "$filename" == "task3_lfs_files.png" ]]; then
    lfs_entry_count="$(grep -Eci '^[[:space:]]*[0-9a-z]{6,}[[:space:]]+[*-]?[[:space:]]*[^[:space:]]+[.]bin' <<<"$ocr_text" || true)"
    if (( lfs_entry_count < 3 )) && ! grep -Eqi '3[[:space:]]*/[[:space:]]*3' <<<"$ocr_text"; then
      feedback+=("$filename: three LFS-tracked .bin file entries were not clearly detected (0)")
      continue
    fi

    lfs_size_count="$(grep -Eci '[.]bin.*(((10[1-9]|1[1-9][0-9]|[2-9][0-9]{2,})([.][0-9]+)?[[:space:]]*(mb|mib))|([1-9][0-9]*([.][0-9]+)?[[:space:]]*(gb|gib)))' <<<"$ocr_text" || true)"
    if (( lfs_size_count < 3 )); then
      feedback+=("$filename: sizes above 100 MiB were not clearly detected for all three LFS files (0)")
      continue
    fi
  fi

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

# Screenshot evidence accounts for 90% of the marks and the three required
# assignment files account for 10%. Each check inside its component has equal
# weight. Scale both components to the TOTAL_MARKS supplied by the workflow.
score="$(python3 - "$passed" "$required" "$artifact_passed" "$artifact_required" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

screenshot_passed, screenshot_required, artifact_passed, artifact_required, total = map(
    Decimal, sys.argv[1:]
)
value = (
    screenshot_passed / screenshot_required * total * Decimal("0.90")
    + artifact_passed / artifact_required * total * Decimal("0.10")
).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(value)
PY
)"

summary="Passed $passed/$required Assignment 01 screenshot checks and $artifact_passed/$artifact_required required assignment-file checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
