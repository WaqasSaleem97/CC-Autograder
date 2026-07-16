#!/usr/bin/env bash
set -u

# Grade Lab 2 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab2/test.sh \
#     work/submissions/Student/CC/Labs/Lab2 \
#     10
#
# Manual example:
#   bash tests/Lab2/test.sh /path/to/CC/Labs/Lab2 10 waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut sort; do
  command -v "$command" >/dev/null 2>&1 || {
    if command -v node >/dev/null 2>&1; then
      json_error "Required grading tool is missing: $command"
    fi
    printf '%s\n' "{\"score\":0,\"feedback\":\"Required grading tool is missing: $command\"}"
    exit 0
  }
done

python3 - <<'PY' >/dev/null 2>&1 || json_error "Python Pillow is required for image validation and duplicate detection."
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
  json_error "Required directory is missing: Labs/Lab2/screenshots"
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

# Every line is: filename|required OCR expressions separated by ;;
# The <GitHub username>@ubuntu identity check is applied to every screenshot.
readarray -t criteria <<'EOF'
git_installation.png|git;;(version|install)
repo_private.png|private;;repository
ssh_keygen.png|ssh-keygen;;ed25519
github_sshkey.png|ssh;;key;;github
ssh_clone.png|git[[:space:]]+clone;;git@github[.]com
git_identity.png|git[[:space:]]+config;;user[.](name|email)
git_config_list.png|git[[:space:]]+config;;user[.](name|email)
git_folder.png|[.]git;;HEAD;;objects;;refs
delete_git.png|rm[[:space:]]+-rf[[:space:]]+[.]git
git_init.png|git[[:space:]]+init;;initialized.*git repository
first_commit.png|initial commit;;README[.]md
first_push.png|git[[:space:]]+push;;origin;;main
status1.png|git[[:space:]]+status;;(untracked|modified)
commit_notes.png|notes[.]txt;;commit
bugfix_branch_gui.png|bugfix/user-auth-error
bugfix_branch_local.png|bugfix/user-auth-error;;branch
feature_db_branch.png|feature/db-connection;;git[[:space:]]+push
branch_create.png|feature-1;;(checkout|switch)
feature_commit.png|main[.]py;;new function;;commit
merge.png|git[[:space:]]+merge;;feature-1
push_branches.png|git[[:space:]]+push;;feature-1;;main
pr_creation.png|pull request;;feature/db-connection;;main
pr_merge.png|merged;;pull request
branch_delete.png|deleted;;feature/db-connection
branch_strategy.png|develop;;staging;;feature;;bugfix
branch_merges.png|develop;;staging;;merge
final_merge.png|staging;;main;;merge
pr_create_details.png|pull request;;title;;description
pr_assigned_reviewer.png|reviewer;;pull request
pr_approved.png|approved;;review
pr_request_changes.png|(changes requested|request changes)
pr_rejected.png|(closed|rejected)
pr_updated_with_commits.png|commits;;pull request
pr_merge_confirm.png|merge;;pull request
pr_merged.png|merged;;pull request
pr_branch_deleted.png|deleted;;branch
remote_branch_deleted.png|deleted;;remote;;branch
remote_branch_delete_cmd.png|git[[:space:]]+push;;--delete;;branch
Q1_branch_created.png|git;;branch;;(checkout|switch)
Q1_commit_done.png|commit
Q1_merge_done.png|merge
EOF

required_screenshots=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab2-ocr-${normalized_username}.XXXXXX")"
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
      tesseract "$source_image" "$output_base" --psm 6 2>/dev/null || true
    ' _ "$screenshots_dir" '{}' "$ocr_dir"

# Create one duplicate index for the complete grading run. Screenshots with the
# same filename are compared between students. Exact hashes and perceptual dHash
# distance <= 2 are rejected, preserving the original Lab 2 behavior.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab2-duplicate-images-${duplicate_key}.tsv"

  if [[ ! -f "$duplicate_index" ]]; then
    python3 - "$submissions_root" "$relative_screenshots" "$duplicate_index" <<'PY'
import hashlib
import itertools
import pathlib
import sys
from collections import defaultdict
from PIL import Image, ImageOps

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

def exact_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def dhash(path):
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("L").resize((9, 8))
        if hasattr(image, "get_flattened_data"):
            pixels = list(image.get_flattened_data())
        else:
            pixels = list(image.getdata())
    value = 0
    for row in range(8):
        for column in range(8):
            value = (value << 1) | (
                pixels[row * 9 + column] > pixels[row * 9 + column + 1]
            )
    return value

duplicates = {}
for paths in groups.values():
    fingerprints = {}
    for image in paths:
        try:
            fingerprints[image] = (exact_hash(image), dhash(image))
        except Exception:
            continue

    for left, right in itertools.combinations(fingerprints, 2):
        left_sha, left_dhash = fingerprints[left]
        right_sha, right_dhash = fingerprints[right]
        distance = (left_dhash ^ right_dhash).bit_count()
        if left_sha == right_sha:
            reason = "exact duplicate of another student's same task"
            duplicates[left] = reason
            duplicates[right] = reason
        elif distance <= 2:
            reason = "near-duplicate of another student's same task"
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
  evidence_groups="${rule#*|}"
  image="$screenshots_dir/$filename"

  if [[ ! -f "$image" ]]; then
    feedback+=("$filename: missing (0)")
    continue
  fi

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

  if ! grep -Eqi "${escaped_username}[[:space:]]*@[[:space:]]*ubuntu" <<<"$ocr_text"; then
    feedback+=("$filename: ${github_username}@ubuntu was not clearly detected (0)")
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

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

required=$required_screenshots

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

summary="Passed $passed/$required Lab 2 screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
