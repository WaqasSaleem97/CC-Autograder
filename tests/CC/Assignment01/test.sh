#!/usr/bin/env bash
set -u

# Grade Assignment 01 required files and screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/CC/Assignment01/test.sh \
#     work/submissions/Student/CC/Assignments/Assignment01 \
#     10
#
# Manual example:
#   bash tests/CC/Assignment01/test.sh \
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
grader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# The workflow normalizes Screenshots/screenshots before grading. Keep the
# standalone grader equally forgiving when it is run directly.
if [[ ! -d "$screenshots_dir" ]]; then
  alternate_screenshots_dir="$(
    find "$submission_dir" -mindepth 1 -maxdepth 1 -type d -iname screenshots \
      -print -quit 2>/dev/null || true
  )"
  if [[ -n "$alternate_screenshots_dir" ]]; then
    screenshots_dir="$alternate_screenshots_dir"
  fi
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

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none      - no username requirement
#   username  - the student's GitHub username should appear
#   ubuntu    - the case-insensitive <github-username>@ubuntu prompt should appear
#
# Each expression is one independent task-evidence indicator. A readable image
# earns proportional credit for the indicators OCR can verify instead of losing
# the complete screenshot mark because one word was misread. Alternatives
# inside one expression use normal extended-regex parentheses and |.
readarray -t criteria <<'EOF'
task1_gitea_running.png|ubuntu|(docker|dacker)[[:space:]]+compose[[:space:]]+ps;;gitea;;(postgres|gitea_db|gitea[[:space:]_-]*db|[[:space:]]db[[:space:]]);;(up|running|healthy);;(gitea[[:space:]]+http[[:space:]]+status|http[[:space:]]+status).*200
task1_gitea_repository.png|none|(gitea|:[[:space:]]*3000|repositories);;assignment[[:space:]_@-]*0?[1li];;readme;;(public|20[0-9]{2}[-[:space:]]*[a-z]{2,4}[-[:space:]]*[0-9]{1,3}|fa[0-9]{2}[a-z0-9-]{4,}|registration|roll[[:space:]]*(number|no))
task1_gitea_push.png|ubuntu|git[[:space:]]+push([[:space:]]+-u)?[[:space:]]+[gq]?itea[[:space:]]+main;;([gq]?itea|:[[:space:]]*3000);;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|track.*gitea/main|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_github_push.png|ubuntu|git[[:space:]]+push([[:space:]]+-u)?[[:space:]]+(github|https?[^[:space:]]*github[.]com)[^[:space:]]*[[:space:]]+main;;(github|github[.]com);;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|track.*github/main|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_remotes.png|ubuntu|git[[:space:]]+remote[[:space:]]+-v;;gitea.*(127[.][0o@][.][0o@]([.][li1])?|localhost|:[[:space:]]*[23]?[0o6][0o@][0o@]?);;github.*github[.]com;;fetch;;push
task2_github_repository.png|username|assignment[[:space:]_@-]*0?[1li];;readme;;(github([.]com)?|security[[:space:]]+and[[:space:]]+quality|pull[[:space:]]+requests|insights|agents);;public;;(20[0-9]{2}[-[:space:]]*[a-z]{2,4}[-[:space:]]*[0-9]{1,3}|fa[0-9]{2}[a-z0-9-]{4,}|registration|roll[[:space:]]*(number|no))
task3_lfs_setup.png|ubuntu|(git[[:space:]]+[li1]?fs[[:space:]]+install|git[[:space:]]+[li1]?fs[[:space:]]+initialized|[li1]?fs[[:space:]]+initialized);;(git[[:space:]]+[li1]?fs[[:space:]]+version|git-[li1]?fs/[0-9]);;git[[:space:]]+[li1]?fs[[:space:]]+track;;gitattributes;;[.]bin
task3_lfs_files.png|ubuntu|git[[:space:]]+[li1]?fs[[:space:]]+[li1]?s-files([[:space:]]+--size)?;;[.]bin
task3_lfs_push.png|ubuntu|git[[:space:]]+push([[:space:]]+-u)?[[:space:]]+(github|https?[^[:space:]]*github[.]com)[^[:space:]]*[[:space:]]+main;;(uploading[[:space:]]+[li1]?fs[[:space:]]+objects?|[li1]?fs[[:space:]]+objects?);;(100%|3[[:space:]]*/[[:space:]]*3);;(github|github[.]com)
task4_pages_repository.png|username|github[.]io;;index[.]?htm[li1t];;styles[.]css;;public
task4_pages_deployment.png|username|github[[:space:]_-]*pages;;(deployed|deployment|published|active|success|your[[:space:]]+site[[:space:]]+is[[:space:]]+live);;github[.]io
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

# Resolve required screenshot stems without considering capitalization, image
# extensions, or repeated extensions such as `.PNG.png`.
expected_screenshots=()
for rule in "${criteria[@]}"; do
  expected_screenshots+=("${rule%%|*}")
done

declare -A resolved_screenshots
if [[ -d "$screenshots_dir" ]]; then
  while IFS=$'\t' read -r expected actual; do
    resolved_screenshots["$expected"]="$actual"
  done < <(
    python3 "$grader_root/scripts/resolve_screenshots.py" \
      "$screenshots_dir" "${expected_screenshots[@]}"
  )
fi

# OCR screenshots concurrently. Assignment 01 evidence is limited to normal
# browser and terminal screenshots, so one PSM 11 pass keeps a full-class run
# fast. The shared fuzzy matcher handles the spacing and character substitutions
# Tesseract commonly introduces in usernames.
ocr_dir="$(mktemp -d "/tmp/assignment01-ocr-${normalized_username}.XXXXXX")"
cleanup() {
  rm -rf -- "$ocr_dir"
}
trap cleanup EXIT

available_cpus="$(nproc 2>/dev/null || true)"
if [[ ! "$available_cpus" =~ ^[1-9][0-9]*$ ]]; then
  available_cpus=2
fi

export OMP_THREAD_LIMIT="${OMP_THREAD_LIMIT:-1}"
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

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  image="${resolved_screenshots[$filename]:-}"
  [[ -f "$image" ]] && printf '%s\0%s\0' "$filename" "$image"
done |
  xargs -0 -r -P "$ocr_jobs" -n 2 \
    bash -c '
      output_directory="$1"
      filename="$2"
      source_image="$3"
      output_base="$output_directory/${filename%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _ "$ocr_dir"

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
image_extensions = (".jpeg", ".jpg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif")

def filename_key(name):
    value = name.casefold().rstrip(".")
    while True:
        for extension in image_extensions:
            if value.endswith(extension):
                value = value[:-len(extension)].rstrip(".")
                break
        else:
            return value

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file() and filename_key(image.name):
            groups[filename_key(image.name)].append(image.resolve())

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

full_credit=0
partial_credit=0
screenshot_credit_units=0
feedback=("${artifact_feedback[@]}")

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  remainder="${rule#*|}"
  identity_flag="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  image="${resolved_screenshots[$filename]:-}"

  if [[ "$image" == "__AMBIGUOUS__" ]]; then
    feedback+=("$filename: multiple files match this name when image extensions are ignored (0)")
    continue
  fi

  if [[ -z "$image" || ! -f "$image" ]]; then
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

  # Reject exposed credentials and private-key bodies. The helper ignores
  # harmless horizontal OCR spacing but deliberately preserves line boundaries;
  # otherwise a normal URL and a later user@ubuntu prompt can form a false
  # password-bearing URL when concatenated.
  if python3 "$grader_root/scripts/ocr_evidence.py" credential "$ocr_file"; then
    feedback+=("$filename: exposed credential, token, password, or private-key material is visible (0)")
    continue
  fi

  # Identity is useful ownership evidence, but OCR uncertainty must not erase
  # otherwise valid task evidence. Fuzzy matching tolerates case differences,
  # inserted spaces, and a small number of OCR substitutions. Identity is 15%
  # of a screenshot check; task evidence is 85%.
  identity_required=false
  identity_verified=true
  case "$identity_flag" in
    username)
      identity_required=true
      if ! python3 "$grader_root/scripts/ocr_evidence.py" \
        username "$normalized_username" "$ocr_file"; then
        identity_verified=false
      fi
      ;;
    ubuntu)
      identity_required=true
      if ! python3 "$grader_root/scripts/ocr_evidence.py" \
        prompt "$normalized_username" "$ocr_file"; then
        identity_verified=false
      fi
      ;;
  esac

  # Repair harmless spacing around punctuation before matching commands, URLs,
  # filenames, and IPv4 addresses in noisy OCR output.
  ocr_normalized="$(
    printf '%s' "$ocr_text" |
      sed -E \
        -e 's/[[:space:]]*[.][[:space:]]*/./g' \
        -e 's/[[:space:]]*@[[:space:]]*/@/g' \
        -e 's#[[:space:]]*/[[:space:]]*#/#g' \
        -e 's/[[:space:]]*:[[:space:]]*/:/g' |
      tr '\r\n\t' '   ' |
      tr -s ' '
  )"

  evidence_total=0
  evidence_matched=0
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    evidence_total=$((evidence_total + 1))
    if grep -Eqi -- "$evidence_pattern" <<<"$ocr_normalized"; then
      evidence_matched=$((evidence_matched + 1))
    fi
  done < <(printf '%s\n' "$evidence_groups" | sed 's/;;/\n/g')

  # The Assignment requires three .bin files and each file must be larger than
  # 100 MiB. Count unique filenames rather than requiring every OCR character
  # in each LFS object hash to be perfect. These are two additional independent
  # indicators, so unclear size text earns partial rather than zero credit.
  if [[ "$filename" == "task3_lfs_files.png" ]]; then
    read -r lfs_entry_count lfs_size_count < <(
      python3 - "$ocr_file" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(
    encoding="utf-8", errors="replace"
).casefold()
names = set()
large = set()
for line in text.splitlines():
    filenames = re.findall(r"[a-z0-9_.@-]+[.]bin", line)
    if not filenames:
        continue
    names.update(filenames)
    sizes = re.findall(
        r"([0-9]+(?:[.][0-9]+)?)\s*(m|mb|mib|g|gb|gib)\b", line
    )
    for filename in filenames:
        for number, unit in sizes:
            value = float(number)
            if unit.startswith("g") or value > 100:
                large.add(filename)
                break
print(len(names), len(large))
PY
    )
    evidence_total=$((evidence_total + 2))
    if (( lfs_entry_count >= 3 )); then
      evidence_matched=$((evidence_matched + 1))
    fi
    if (( lfs_size_count >= 3 )); then
      evidence_matched=$((evidence_matched + 1))
    fi
  fi

  if (( evidence_total == 0 || evidence_matched == 0 )); then
    feedback+=("$filename: required task evidence was not detected (0)")
    continue
  fi

  if [[ "$identity_required" == true ]]; then
    credit_units=$((850 * evidence_matched / evidence_total))
    if [[ "$identity_verified" == true ]]; then
      credit_units=$((credit_units + 150))
      identity_note="identity verified"
    else
      identity_note="identity not detected by OCR"
    fi
  else
    credit_units=$((1000 * evidence_matched / evidence_total))
    identity_note=""
  fi

  screenshot_credit_units=$((screenshot_credit_units + credit_units))
  if (( credit_units == 1000 )); then
    full_credit=$((full_credit + 1))
    feedback+=("$filename: passed")
  else
    partial_credit=$((partial_credit + 1))
    if [[ -n "$identity_note" ]]; then
      feedback+=("$filename: partial credit - $evidence_matched/$evidence_total task indicators; $identity_note")
    else
      feedback+=("$filename: partial credit - $evidence_matched/$evidence_total task indicators")
    fi
  fi
done

# Screenshot evidence accounts for 90% of the marks and the three required
# assignment files account for 10%. Each check inside its component has equal
# weight. Scale both components to the TOTAL_MARKS supplied by the workflow.
score="$(python3 - "$screenshot_credit_units" "$required" "$artifact_passed" "$artifact_required" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

screenshot_units, screenshot_required, artifact_passed, artifact_required, total = map(
    Decimal, sys.argv[1:]
)
value = (
    screenshot_units / (screenshot_required * Decimal("1000"))
    * total
    * Decimal("0.90")
    + artifact_passed / artifact_required * total * Decimal("0.10")
).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(value)
PY
)"

screenshot_equivalent="$(python3 - "$screenshot_credit_units" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

value = (Decimal(sys.argv[1]) / Decimal("1000")).quantize(
    Decimal("0.01"), rounding=ROUND_HALF_UP
)
print(value)
PY
)"

summary="Earned $screenshot_equivalent/$required screenshot-check equivalents ($full_credit full, $partial_credit partial) and passed $artifact_passed/$artifact_required required assignment-file checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
