#!/usr/bin/env bash
set -u

# Grade Lab 3 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab3/test.sh \
#     work/submissions/Student/CC/Labs/Lab03 \
#     10
#
# Manual example:
#   bash tests/Lab3/test.sh /path/to/CC/Labs/Lab03 10 waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find; do
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
  json_error "Required directory is missing: Labs/Lab03/screenshots"
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
#   none     - no username requirement
#   username - the GitHub username must be visible
readarray -t criteria <<'EOF'
remote_edit.png|none|(github|readme);;(commit|committed|remote)
local_commit.png|none|git[[:space:]]+commit;;local.*update
push_error.png|none|git[[:space:]]+push;;(rejected|failed[[:space:]]+to[[:space:]]+push|fetch[[:space:]]+first)
merge_commit.png|none|git[[:space:]]+pull;;(no-rebase|merge|merging)
push_after_merge.png|none|git[[:space:]]+push;;(main|objects|up-to-date|set[[:space:]]+up[[:space:]]+to[[:space:]]+track)
rebase_pull.png|none|git[[:space:]]+pull;;rebase
push_after_rebase.png|none|git[[:space:]]+push;;(main|objects|up-to-date)
remote_conflict_edit.png|none|(github|readme);;(conflict|remote);;(commit|committed)
local_conflict_edit.png|none|(readme|visual[[:space:]]+studio[[:space:]]+code|vscode);;(local|conflict|updated)
local_conflict_commit.png|none|git[[:space:]]+commit;;(local|conflict)
conflict_push_error.png|none|git[[:space:]]+push;;(rejected|failed[[:space:]]+to[[:space:]]+push|fetch[[:space:]]+first)
conflict_message.png|none|git[[:space:]]+pull;;rebase;;conflict
resolved_readme.png|none|readme;;(local|remote|resolved|updated)
rebase_continue.png|none|git[[:space:]]+rebase;;continue
push_after_resolve.png|none|git[[:space:]]+push;;(main|objects|up-to-date)
push_textfiles.png|none|git[[:space:]]+push;;textfiles
gitignore_push.png|none|(gitignore|[.]gitignore);;git[[:space:]]+push
repo_still_has_textfiles.png|none|textfiles;;(github|repository|a[.]txt|b[.]txt|c[.]txt)
rm_cached_push.png|none|(rm[[:space:]]+-r[[:space:]]+--cached|removed[[:space:]]+tracked[[:space:]]+textfiles);;git[[:space:]]+push
repo_textfiles_removed.png|none|(github|repository);;(textfiles|[.]gitignore)
modified_readme.png|none|(readme|README);;(commit|changes|feature-branch)
checkout_error.png|none|git[[:space:]]+checkout;;(local[[:space:]]+changes|overwritten[[:space:]]+by[[:space:]]+checkout|stash)
stash_command.png|none|git[[:space:]]+stash;;(saved|working[[:space:]]+directory|index[[:space:]]+state)
branch_switched.png|none|git[[:space:]]+checkout;;main;;(switched|already[[:space:]]+on)
back_to_feature.png|none|git[[:space:]]+checkout;;feature-branch;;(switched|already[[:space:]]+on)
status_clean.png|none|git[[:space:]]+status;;(working[[:space:]]+tree[[:space:]]+clean|nothing[[:space:]]+to[[:space:]]+commit)
stash_pop.png|none|git[[:space:]]+stash;;pop;;(changes[[:space:]]+not[[:space:]]+staged|dropped|feature-branch)
log_before_checkout.png|none|git[[:space:]]+log;;oneline
detached_head.png|none|git[[:space:]]+checkout;;(detached[[:space:]]+head|HEAD[[:space:]]+is[[:space:]]+now[[:space:]]+at)
back_to_main.png|none|git[[:space:]]+checkout;;main;;(switched|already[[:space:]]+on)
first_commit.png|none|git[[:space:]]+commit;;added[[:space:]]+test[[:space:]]+line
second_commit.png|none|git[[:space:]]+commit;;second[[:space:]]+test[[:space:]]+commit
log_before_reset.png|none|git[[:space:]]+log;;oneline;;(added[[:space:]]+test[[:space:]]+line|second[[:space:]]+test[[:space:]]+commit)
file_before_reset.png|none|(readme|test[[:space:]]+line|second[[:space:]]+test|edit)
soft_reset.png|none|git[[:space:]]+reset;;--soft;;HEAD~1
log_after_soft_reset.png|none|git[[:space:]]+log;;oneline
file_after_soft_reset.png|none|(readme|test[[:space:]]+line|second[[:space:]]+test|edit)
file_after_hard_reset.png|none|(readme|test[[:space:]]+line|second[[:space:]]+test|edit|commit)
hard_reset.png|none|git[[:space:]]+reset;;--hard;;HEAD~1
log_after_hard_reset.png|none|git[[:space:]]+log;;oneline
first_amend_commit.png|none|git[[:space:]]+commit;;fix[[:space:]]+log[[:space:]]+message
amend_commit.png|none|git[[:space:]]+commit;;--amend
commit_temp_file.png|none|(temp[.]txt|temporary[[:space:]]+text);;git[[:space:]]+(commit|push)
revert_commit.png|none|git[[:space:]]+revert;;[0-9a-f]{5,40}
revert_push.png|none|git[[:space:]]+push;;(main|objects|revert)
new_branch.png|none|git[[:space:]]+checkout;;-b;;test-force
force_commit.png|none|git[[:space:]]+commit;;(test-force|change|file)
push_force_branch.png|none|git[[:space:]]+push;;test-force
hard_reset_force.png|none|git[[:space:]]+reset;;--hard;;HEAD~1
normal_push.png|none|git[[:space:]]+push;;test-force;;(rejected|non-fast-forward|failed[[:space:]]+to[[:space:]]+push)
force_push.png|none|git[[:space:]]+push;;test-force;;--force
forked_gitea.png|username|(forked[[:space:]]+from|gitea);;(github|code|repository)
codespace_loading.png|none|(codespace|setting[[:space:]]+up[[:space:]]+your[[:space:]]+codespace|opening[[:space:]]+remote)
docker_up.png|none|docker[[:space:]]+compose;;up;;(running|started|created|gitea)
gitea_install_page.png|none|gitea;;(initial[[:space:]]+configuration|installation|database[[:space:]]+settings)
admin_setup.png|none|gitea;;(administrator|admin|account[[:space:]]+settings)
gitea_dashboard.png|none|gitea;;(dashboard|repositories|activities|explore)
gitea_new_repo.png|none|gitea;;(new[[:space:]]+repository|repository[[:space:]]+name|quick[[:space:]]+setup)
github_pages_repo.png|username|github[.]io;;(public|repository|quick[[:space:]]+setup)
local_static_site.png|none|(index[.]html|html);;(css|javascript|js|portfolio|cv)
push_static_site.png|username|git[[:space:]]+push;;github[.]io;;(main|objects|set[[:space:]]+up[[:space:]]+to[[:space:]]+track)
github_pages_settings.png|username|(github[[:space:]]+pages|pages);;(published|site[[:space:]]+is[[:space:]]+live|github[.]io)
live_site.png|username|(portfolio|curriculum|resume|cv|about|education|experience|projects)
Q1_remote_edit.png|none|(github|readme);;(commit|remote)
Q1_local_edit.png|none|(git[[:space:]]+commit|readme);;local
Q1_push_error.png|none|git[[:space:]]+push;;(rejected|failed[[:space:]]+to[[:space:]]+push|fetch[[:space:]]+first)
Q1_merge_resolution.png|none|git[[:space:]]+pull;;(merge|no-rebase);;git[[:space:]]+push
Q1_rebase_resolution.png|none|git[[:space:]]+pull;;rebase;;git[[:space:]]+push
Q2_remote_conflict_edit.png|none|(github|readme);;(conflict|remote);;commit
Q2_local_conflict_edit.png|none|(readme|git[[:space:]]+commit);;(local|conflict)
Q2_conflict_push_error.png|none|git[[:space:]]+push;;(rejected|failed[[:space:]]+to[[:space:]]+push|fetch[[:space:]]+first)
Q2_rebase_conflict.png|none|git[[:space:]]+pull;;rebase;;conflict
Q2_resolved_file.png|none|(readme|resolved);;(local|remote|conflict)
Q2_resolution_complete.png|none|git[[:space:]]+(add|rebase);;(continue|push|main)
Q3_folder_created.png|none|(docfiles|folder);;(mkdir|file|created)
Q3_files_pushed.png|none|git[[:space:]]+push;;(docfiles|files|objects)
Q3_gitignore_added.png|none|(gitignore|[.]gitignore);;docfiles
Q3_gitignore_pushed.png|none|(gitignore|[.]gitignore);;git[[:space:]]+push
Q3_folder_untracked.png|none|git[[:space:]]+rm;;--cached;;(docfiles|folder)
Q3_folder_removed_github.png|none|(github|repository);;(docfiles|[.]gitignore)
Q4_first_commit.png|none|git[[:space:]]+commit;;(commit|change)
Q4_second_commit.png|none|git[[:space:]]+commit;;(second|commit|change)
Q4_commit_history.png|none|git[[:space:]]+log;;oneline
Q4_soft_reset.png|none|git[[:space:]]+reset;;--soft;;HEAD~1
Q4_third_commit.png|none|git[[:space:]]+commit;;(third|commit|change)
Q4_hard_reset.png|none|git[[:space:]]+reset;;--hard;;HEAD~1
EOF

required_screenshots=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab3-ocr-${normalized_username}.XXXXXX")"
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

# Compare same-task screenshots among students selected in this workflow run.
# Exact duplicates are rejected for every task. Perceptual near-duplicates are
# restricted to account/site identity evidence to reduce false positives.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab3-duplicate-images-${duplicate_key}.tsv"

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

identity_files = {
    "forked_gitea.png",
    "github_pages_repo.png",
    "push_static_site.png",
    "github_pages_settings.png",
    "live_site.png",
}

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
        pixels = list(image.getdata())
    value = 0
    for row in range(8):
        for column in range(8):
            value = (value << 1) | (
                pixels[row * 9 + column] > pixels[row * 9 + column + 1]
            )
    return value

duplicates = {}
for filename, paths in groups.items():
    fingerprints = {}
    for image in paths:
        try:
            fingerprints[image] = (hashlib.sha256(image.read_bytes()).hexdigest(), dhash(image))
        except Exception:
            continue

    for left, right in itertools.combinations(fingerprints, 2):
        left_sha, left_dhash = fingerprints[left]
        right_sha, right_dhash = fingerprints[right]

        if left_sha == right_sha:
            duplicates[left] = "exact duplicate of another student's same task"
            duplicates[right] = "exact duplicate of another student's same task"
            continue

        if filename in identity_files and (left_dhash ^ right_dhash).bit_count() <= 2:
            duplicates[left] = "near-duplicate of another student's identity evidence"
            duplicates[right] = "near-duplicate of another student's identity evidence"

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

  # Verify that Pillow can decode the image. No minimum-dimension rule is used.
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

  if [[ "$identity_flag" == "username" ]]; then
    if ! grep -Eqi "(^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)" <<<"$ocr_text"; then
      feedback+=("$filename: GitHub username was not clearly detected (0)")
      continue
    fi
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

# The README requires a Word report and either a PDF or a separate solution
# Markdown file. README.md itself does not count as the solution Markdown file.
mapfile -d '' word_reports < <(
  find "$submission_dir" -maxdepth 1 -type f \
    \( -iname '*.doc' -o -iname '*.docx' \) -size +0c -print0
)
mapfile -d '' alternate_reports < <(
  find "$submission_dir" -maxdepth 1 -type f \
    \( -iname '*.pdf' -o -iname '*.md' \) \
    ! -iname 'README.md' -size +0c -print0
)

if (( ${#word_reports[@]} == 0 )); then
  feedback+=("submission report: non-empty Word file is missing (0)")
elif (( ${#alternate_reports[@]} == 0 )); then
  feedback+=("submission report: non-empty PDF or solution Markdown file is missing (0)")
else
  passed=$((passed + 1))
  feedback+=("submission report: passed")
fi

required=$((required_screenshots + 1))

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

summary="Passed $passed/$required Lab 3 checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
