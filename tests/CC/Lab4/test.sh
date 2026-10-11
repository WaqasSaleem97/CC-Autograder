#!/usr/bin/env bash
set -u

# Grade Lab 4 screenshot and file evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/CC/Lab4/test.sh \
#     work/submissions/Student/CC/Labs/Lab04 \
#     10
#
# Manual example:
#   bash tests/CC/Lab4/test.sh /path/to/CC/Labs/Lab04 10 waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut cmp; do
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

if [[ ! -d "$screenshots_dir" ]]; then
  json_error "Required directory is missing: Labs/Lab04/screenshots"
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

# The shared screenshot normalizer exposes submitted images through lowercase
# .png names. Keep the published filename spelling in the criteria for readable
# feedback, but resolve it case-insensitively at grading time.
canonical_screenshot_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none     - no username requirement
#   username - the GitHub username must appear somewhere in the screenshot
#   prompt   - a terminal prompt containing <GitHub username>@ubuntu must appear
#   lab4user - a terminal prompt containing lab4user@ubuntu must appear
readarray -t criteria <<'EOF'
vm_settings.png|none|(memory|ram);;(processor|cpu);;(hard[[:space:]]+disk|disk);;network
whoami_pwd.png|prompt|whoami;;pwd;;/home/
ls_root.png|prompt|ls[[:space:]]+-la[[:space:]]+/;;(bin|boot);;etc;;usr;;var
ls_bin.png|prompt|ls[[:space:]]+-la[[:space:]]+/bin;;(root|bin|usr)
ls_sbin.png|prompt|ls[[:space:]]+-la[[:space:]]+/sbin;;(root|sbin|usr)
ls_usr.png|prompt|ls[[:space:]]+-la[[:space:]]+/usr;;(bin|lib);;(local|share)
ls_opt.png|prompt|ls[[:space:]]+-la[[:space:]]+/opt;;(root|total|drwx)
ls_etc.png|prompt|ls[[:space:]]+-la[[:space:]]+/etc;;(passwd|group|hosts|ssh)
ls_dev.png|prompt|ls[[:space:]]+-la[[:space:]]+/dev;;(null|tty|random|disk)
ls_var.png|prompt|ls[[:space:]]+-la[[:space:]]+/var;;(log|lib|cache|tmp)
ls_tmp.png|prompt|ls[[:space:]]+-la[[:space:]]+/tmp;;(root|total|drwx)
home_ls.png|prompt|ls[[:space:]]+-la[[:space:]]+(~|/home);;[.](bashrc|profile|ssh)
answers_md.png|none|(^|[^[:alnum:]_/.-])/bin([^[:alnum:]_/.-]|$);;(^|[^[:alnum:]_/.-])/usr/bin([^[:alnum:]_/.-]|$);;(^|[^[:alnum:]_/.-])/usr/local/bin([^[:alnum:]_/.-]|$)
mkdir_workspace.png|prompt|mkdir;;lab4/workspace/python_project
cd_workspace.png|prompt|cd;;lab4/workspace/python_project
pwd_workspace.png|prompt|pwd;;/lab4/workspace/python_project
nano_readme.png|none|(nano|GNU[[:space:]]+nano);;Lab[[:space:]]+4[[:space:]]+README
nano_main.png|none|(nano|GNU[[:space:]]+nano);;print;;hello[[:space:]]+lab4
nano_env.png|none|(nano|GNU[[:space:]]+nano);;ENV[[:space:]]*=[[:space:]]*lab4
workspace_ls.png|prompt|ls[[:space:]]+-la;;README[.]md;;main[.]py;;[.]env
cp_readme.png|prompt|cp[[:space:]]+README[.]md[[:space:]]+README[.]copy[.]md
mv_readme.png|prompt|mv[[:space:]]+README[.]copy[.]md[[:space:]]+README[.]dev[.]md
rm_readme.png|prompt|rm[[:space:]]+README[.]dev[.]md
mkdir_java_app.png|prompt|mkdir;;lab4/workspace/java_app
cp_recursive.png|prompt|cp[[:space:]]+-r;;python_project;;java_app_copy
copy_verify.png|prompt|ls[[:space:]]+-la;;lab4/workspace;;python_project;;java_app_copy
history.png|prompt|history;;(mkdir|cd|nano|cp|mv|rm)
tab_completion.png|prompt|(python_project|java_app|README|main[.]py|lab4/workspace)
uname.png|prompt|uname[[:space:]]+-a;;linux
cpuinfo.png|prompt|cat[[:space:]]+/proc/cpuinfo;;model[[:space:]]+name
meminfo.png|prompt|free[[:space:]]+-h;;total;;available
diskinfo.png|prompt|df[[:space:]]+-h;;filesystem;;(size|available|mounted)
os-release.png|prompt|cat[[:space:]]+/etc/os-release;;(ubuntu|PRETTY_NAME|VERSION)
processes.png|prompt|ps[[:space:]]+aux;;(USER|PID);;(COMMAND|CMD)
adduser_lab4user.png|prompt|(adduser|adding[[:space:]]+user);;lab4user
lab4user_passwd.png|prompt|getent[[:space:]]+passwd[[:space:]]+lab4user;;lab4user;;/home/lab4user
su_lab4user.png|lab4user|su[[:space:]]+-[[:space:]]+lab4user
exit_back.png|prompt|exit
EOF

required_screenshots=${#criteria[@]}
if (( required_screenshots != 38 )); then
  json_error "Trusted Lab 4 grader configuration must contain exactly 38 core screenshot checks."
fi

# Explicitly optional evidence from the README. These files are reported but
# do not increase or reduce the student's score.
optional_files=(
  vm_login.png
  sudo_whoami.png
  deluser.png
)

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab4-ocr-${normalized_username}.XXXXXX")"
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
    canonical_filename="$(canonical_screenshot_name "$filename")"
    [[ -f "$screenshots_dir/$canonical_filename" ]] && printf '%s\n' "$canonical_filename"
  done |
  xargs -r -P "$ocr_jobs" -I '{}' \
    bash -c '
      source_image="$1/$2"
      output_base="$3/${2%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _ "$screenshots_dir" '{}' "$ocr_dir"

# Build an exact-duplicate index for screenshots with the same task filename
# across all students selected in this workflow run. Both copies receive zero.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab4-duplicate-images-${duplicate_key}.tsv"

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
  canonical_filename="$(canonical_screenshot_name "$filename")"
  image="$screenshots_dir/$canonical_filename"

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

  ocr_file="$ocr_dir/${canonical_filename%.*}.txt"
  ocr_text=""
  if [[ -f "$ocr_file" ]]; then
    ocr_text="$(tr '[:upper:]' '[:lower:]' < "$ocr_file")"
  fi

  if [[ -z "${ocr_text//[[:space:]]/}" ]]; then
    feedback+=("$filename: unreadable OCR (0)")
    continue
  fi

  if [[ "$identity_flag" == "username" ]]; then
    if ! python3 "$grader_root/scripts/ocr_evidence.py" \
      username "$normalized_username" "$ocr_file"; then
      feedback+=("$filename: GitHub username was not clearly detected (0)")
      continue
    fi
  elif [[ "$identity_flag" == "prompt" ]]; then
    if ! python3 "$grader_root/scripts/ocr_evidence.py" \
      prompt "$normalized_username" "$ocr_file"; then
      feedback+=("$filename: ${github_username}@ubuntu terminal prompt was not clearly detected (0)")
      continue
    fi
  elif [[ "$identity_flag" == "lab4user" ]]; then
    if ! python3 "$grader_root/scripts/ocr_evidence.py" \
      prompt lab4user "$ocr_file"; then
      feedback+=("$filename: lab4user@ubuntu terminal prompt was not clearly detected (0)")
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

  # These screenshots must contain an explanation, not only the directory
  # names. OCR can lose punctuation, so use a modest word threshold instead of
  # enforcing exact sentences or phrasing.
  if [[ "$filename" == "answers_md.png" ]]; then
    minimum_words=20
    word_count="$(python3 - "$ocr_file" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
print(len(re.findall(r"[A-Za-z0-9][A-Za-z0-9_/-]*", text)))
PY
)"
    if (( word_count < minimum_words )); then
      feedback+=("$filename: written explanation is too short to demonstrate the required work (0)")
      continue
    fi
  fi

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

# Validate the exact workspace structure required by the current Lab 04 README.
workspace_dir="$submission_dir/workspace"
project_dir="$workspace_dir/python_project"
copy_dir="$workspace_dir/java_app_copy"
project_ok=true
project_problem=""

if [[ ! -d "$workspace_dir" ]]; then
  project_ok=false
  project_problem="workspace directory is missing"
elif [[ ! -d "$project_dir" ]]; then
  project_ok=false
  project_problem="workspace/python_project directory is missing"
elif [[ ! -s "$project_dir/README.md" ]]; then
  project_ok=false
  project_problem="README.md is missing or empty"
elif ! grep -Fqi "Lab 4 README" "$project_dir/README.md"; then
  project_ok=false
  project_problem="README.md does not contain the required text"
elif [[ ! -s "$project_dir/main.py" ]]; then
  project_ok=false
  project_problem="main.py is missing or empty"
elif ! grep -Eqi "print[[:space:]]*\\([[:space:]]*['\"]hello[[:space:]]+lab4['\"][[:space:]]*\\)" "$project_dir/main.py"; then
  project_ok=false
  project_problem="main.py does not contain the required print statement"
elif [[ ! -s "$project_dir/.env" ]]; then
  project_ok=false
  project_problem=".env is missing or empty"
elif ! grep -Eqi '^ENV[[:space:]]*=[[:space:]]*lab4[[:space:]]*$' "$project_dir/.env"; then
  project_ok=false
  project_problem=".env does not contain ENV=lab4"
fi

if [[ "$project_ok" == true ]]; then
  passed=$((passed + 1))
  feedback+=("workspace/python_project: passed")
else
  feedback+=("workspace/python_project: $project_problem (0)")
fi

copy_ok=true
copy_problem=""
if [[ ! -d "$copy_dir" ]]; then
  copy_ok=false
  copy_problem="workspace/java_app_copy directory is missing"
elif [[ ! -s "$copy_dir/README.md" || ! -s "$copy_dir/main.py" || ! -s "$copy_dir/.env" ]]; then
  copy_ok=false
  copy_problem="copied README.md, main.py, or .env is missing or empty"
elif [[ "$project_ok" != true ]]; then
  copy_ok=false
  copy_problem="the source python_project is invalid, so its copy cannot be verified"
elif ! cmp -s "$project_dir/README.md" "$copy_dir/README.md" \
  || ! cmp -s "$project_dir/main.py" "$copy_dir/main.py" \
  || ! cmp -s "$project_dir/.env" "$copy_dir/.env"; then
  copy_ok=false
  copy_problem="copied project files do not match workspace/python_project"
fi

if [[ "$copy_ok" == true ]]; then
  passed=$((passed + 1))
  feedback+=("workspace/java_app_copy: passed")
else
  feedback+=("workspace/java_app_copy: $copy_problem (0)")
fi

# The current Lab 04 submission requires one exact, non-empty PDF. A Word file
# or a differently named PDF does not replace Lab4_Solution.pdf.
solution_pdf="$submission_dir/Lab4_Solution.pdf"
pdf_ok=true
pdf_problem=""
if [[ ! -s "$solution_pdf" ]]; then
  pdf_ok=false
  pdf_problem="Lab4_Solution.pdf is missing or empty"
elif ! python3 - "$solution_pdf" <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as source:
    assert source.read(5) == b"%PDF-"
PY
then
  pdf_ok=false
  pdf_problem="Lab4_Solution.pdf is not a valid PDF file"
fi

if [[ "$pdf_ok" == true ]]; then
  passed=$((passed + 1))
  feedback+=("Lab4_Solution.pdf: passed")
else
  feedback+=("Lab4_Solution.pdf: $pdf_problem (0)")
fi

optional_present=0
for optional_file in "${optional_files[@]}"; do
  canonical_optional="$(canonical_screenshot_name "$optional_file")"
  [[ -f "$screenshots_dir/$canonical_optional" ]] && optional_present=$((optional_present + 1))
done

required=$((required_screenshots + 3))

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

summary="Passed $passed/$required Lab 4 required checks. Optional evidence present: $optional_present/${#optional_files[@]} (not scored). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
