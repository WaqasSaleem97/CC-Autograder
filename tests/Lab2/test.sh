#!/usr/bin/env bash
set -u

# Usage: test.sh SUBMISSION_DIRECTORY TOTAL_MARKS
# Example: test.sh work/submissions/Student/CC/Labs/Lab2 100

submission_dir="$(realpath "$1")"
total_marks="$2"
screenshots_dir="$submission_dir/screenshots"

for command in tesseract python3 git node sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    node -e 'console.log(JSON.stringify({score:0,feedback:process.argv[1]}))' "Required grading tool is missing: $command"
    exit 0
  }
done

python3 - <<'PY' >/dev/null 2>&1 || {
from PIL import Image
PY
  node -e 'console.log(JSON.stringify({score:0,feedback:"Python Pillow is required for perceptual duplicate detection."}))'
  exit 0
}

if [[ ! -d "$screenshots_dir" ]]; then
  node -e 'console.log(JSON.stringify({score:0,feedback:"Required directory is missing: Labs/Lab2/screenshots"}))'
  exit 0
fi

# Obtain the expected GitHub username from the cloned repository's origin URL.
remote_url="$(git -C "$submission_dir" remote get-url origin 2>/dev/null || true)"
github_username="$(printf '%s' "$remote_url" | sed -E 's#.*github\.com[:/]([^/]+)/.*#\1#; s#\.git$##')"

if [[ -z "$github_username" || "$github_username" == "$remote_url" ]]; then
  node -e 'console.log(JSON.stringify({score:0,feedback:"The GitHub username could not be determined from repository origin."}))'
  exit 0
fi

normalized_username="$(printf '%s' "$github_username" | tr '[:upper:]' '[:lower:]')"
escaped_username="$(printf '%s' "$normalized_username" | sed 's/[][\.^$*+?{}|()]/\\&/g')"

# Every line is: filename|task-specific OCR regular expression.
# The username@ubuntu check is applied separately to every screenshot.
readarray -t criteria <<'EOF'
git_installation.png|git;;(version|install)
repo_private.png|private;;repository
ssh_keygen.png|ssh-keygen;;ed25519
github_sshkey.png|ssh;;key;;github
ssh_clone.png|git[[:space:]]+clone;;git@github\.com
git_identity.png|git[[:space:]]+config;;user\.(name|email)
git_config_list.png|git[[:space:]]+config;;user\.(name|email)
git_folder.png|\.git;;HEAD;;objects;;refs
delete_git.png|rm[[:space:]]+-rf[[:space:]]+\.git
git_init.png|git[[:space:]]+init;;initialized.*git repository
first_commit.png|initial commit;;README\.md
first_push.png|git[[:space:]]+push;;origin;;main
status1.png|git[[:space:]]+status;;(untracked|modified)
commit_notes.png|notes\.txt;;commit
bugfix_branch_gui.png|bugfix/user-auth-error
bugfix_branch_local.png|bugfix/user-auth-error;;branch
feature_db_branch.png|feature/db-connection;;git[[:space:]]+push
branch_create.png|feature-1;;(checkout|switch)
feature_commit.png|main\.py;;new function;;commit
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

# Build one duplicate index for the whole workflow. It compares screenshots only
# when they have the same filename/task. Exact duplicates and dHash distance <= 2
# are considered duplicates. A fresh GitHub runner means this cache is per run.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
submissions_root="$(dirname "$(dirname "$repo_root")")"
duplicate_index="/tmp/lab2-duplicate-images.tsv"

if [[ ! -f "$duplicate_index" ]]; then
  python3 - "$submissions_root" "$duplicate_index" <<'PY'
import hashlib
import itertools
import pathlib
import sys
from collections import defaultdict
from PIL import Image, ImageOps

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])
groups = defaultdict(list)

for image in root.glob("*/*/Labs/Lab2/screenshots/*"):
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
            value = (value << 1) | (pixels[row * 9 + column] > pixels[row * 9 + column + 1])
    return value

duplicates = set()
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
        if left_sha == right_sha or distance <= 2:
            duplicates.add(left)
            duplicates.add(right)

output.write_text("".join(f"{path}\n" for path in sorted(duplicates)), encoding="utf-8")
PY
fi

passed=0
required=${#criteria[@]}
feedback=()

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  evidence_groups="${rule#*|}"
  image="$screenshots_dir/$filename"

  if [[ ! -f "$image" ]]; then
    feedback+=("$filename: missing (0)")
    continue
  fi

  # An invalid/corrupt image causes OCR to fail and receives zero.
  ocr_text="$(tesseract "$image" stdout --psm 6 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ -z "${ocr_text//[[:space:]]/}" ]]; then
    feedback+=("$filename: unreadable OCR (0)")
    continue
  fi

  if ! grep -Eqi "${escaped_username}[[:space:]]*@[[:space:]]*ubuntu" <<<"$ocr_text"; then
    feedback+=("$filename: GitHub username@ubuntu not clearly detected (0)")
    continue
  fi

  evidence_ok=true
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    if ! grep -Eqi -- "$evidence_pattern" <<<"$ocr_text"; then evidence_ok=false; break; fi
  done < <(printf '%s' "$evidence_groups" | sed 's/;;/\n/g')
  if [[ "$evidence_ok" != true ]]; then
    feedback+=("$filename: required task evidence not detected (0)")
    continue
  fi

  canonical_image="$(realpath "$image")"
  if grep -Fqx "$canonical_image" "$duplicate_index"; then
    feedback+=("$filename: duplicate or near-duplicate found in another student's same task (0)")
    continue
  fi

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

# Each required screenshot has equal weight. Scale the result to TOTAL_MARKS.
score="$(python3 - "$passed" "$required" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys
passed, required, total = map(Decimal, sys.argv[1:])
value = (passed / required * total).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(value)
PY
)"

summary="Passed $passed/$required screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e 'console.log(JSON.stringify({score:Number(process.argv[1]),feedback:process.argv[2]}))' "$score" "$summary"
