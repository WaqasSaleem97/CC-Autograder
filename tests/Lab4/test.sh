#!/usr/bin/env bash
set -u

# Grade Lab 4 screenshot and file evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab4/test.sh \
#     work/submissions/Student/CC/Labs/Lab04 \
#     10
#
# Manual example:
#   bash tests/Lab4/test.sh /path/to/CC/Labs/Lab04 10 waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut; do
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
escaped_username="$(printf '%s' "$normalized_username" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none     - no username requirement
#   username - the GitHub username must appear somewhere in the screenshot
#   prompt   - a terminal prompt containing <GitHub username>@<host> must appear
#   lab4user - a terminal prompt containing lab4user@<host> must appear
readarray -t criteria <<'EOF'
vm_settings.png|none|vmware;;(memory|ram);;(processor|cpu);;(hard[[:space:]]+disk|disk);;network
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
answers_md.png|none|/bin;;/usr/bin;;/usr/local/bin
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
copy_verify.png|prompt|ls[[:space:]]+-la;;lab4/workspace;;(python_project|java_app_copy);;java_app
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
sudo_whoami.png|lab4user|sudo[[:space:]]+whoami;;(not[[:space:]]+in[[:space:]]+the[[:space:]]+sudoers|permission[[:space:]]+denied|not[[:space:]]+allowed|may[[:space:]]+not[[:space:]]+run)
exit_back.png|prompt|exit
Q1_remote_connection.png|prompt|ssh[[:space:]]+[^[:space:]]+@([0-9]{1,3}[.]){3}[0-9]{1,3};;(welcome|last[[:space:]]+login|ubuntu)
Q1_user_verification.png|prompt|whoami;;pwd;;/home/
Q1_host_confirmation.png|prompt|(hostname|hostnamectl);;(ubuntu|static[[:space:]]+hostname|virtualization)
Q2_root_listing.png|prompt|ls[[:space:]]+-la[[:space:]]+/;;(bin|etc);;usr;;var
Q2_os_version.png|prompt|(cat[[:space:]]+/etc/os-release|lsb_release);;(ubuntu|PRETTY_NAME|VERSION)
Q2_directory_evidence.png|prompt|(/bin|bin);;(/sbin|sbin);;(/usr|usr);;(/opt|opt);;(/etc|etc);;(/dev|dev);;(/var|var);;(/tmp|tmp)
Q2_hidden_files.png|prompt|ls[[:space:]]+-la[[:space:]]+(~|/home);;[.](bashrc|profile|ssh)
Q2_report_file.png|none|(/bin|bin);;(/usr/bin|usr/bin);;(/usr/local/bin|usr/local/bin)
Q3_workspace_created.png|prompt|mkdir;;(workspace|analysis|evidence)
Q3_files_created.png|prompt|(nano|touch|ls[[:space:]]+-la);;([.]env|hidden|[.]txt|file)
Q3_backup_handling.png|prompt|cp;;mv;;rm
Q3_workspace_backup.png|prompt|cp[[:space:]]+-r;;(workspace|backup|evidence)
Q3_command_history.png|prompt|history;;(mkdir|cp|mv|rm)
Q3_autocomplete.png|prompt|(workspace|backup|README|file|analysis|evidence)
Q4_system_info.png|prompt|(uname[[:space:]]+-a|cat[[:space:]]+/etc/os-release|lsb_release);;(linux|ubuntu|kernel)
Q4_resource_info.png|prompt|(cat[[:space:]]+/proc/cpuinfo|lscpu);;(free[[:space:]]+-h|memory);;(df[[:space:]]+-h|filesystem)
Q4_process_list.png|prompt|ps[[:space:]]+aux;;(USER|PID);;(COMMAND|CMD)
Q5_user_created.png|prompt|(adduser|adding[[:space:]]+user);;lab4user
Q5_user_verified.png|prompt|getent[[:space:]]+passwd[[:space:]]+lab4user;;/home/lab4user
Q5_user_login.png|lab4user|su[[:space:]]+-[[:space:]]+lab4user
Q5_permission_denied.png|lab4user|sudo;;(permission[[:space:]]+denied|not[[:space:]]+in[[:space:]]+the[[:space:]]+sudoers|not[[:space:]]+allowed|may[[:space:]]+not[[:space:]]+run)
Q5_switch_back.png|prompt|exit
Q5_authlog_analysis.png|prompt|/var/log/auth[.]log;;lab4user;;(session|authentication|sudo|su|failed|accepted)
EOF

required_screenshots=${#criteria[@]}

# Explicitly optional evidence from the README. These files are reported but
# do not increase or reduce the student's score.
optional_files=(
  vm_login.png
  deluser.png
  nano_run_demo.png
  chmod_run_demo.png
  run_demo_output.png
  run_demo_output_sudo.png
  Q5_user_removed.png
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
    [[ -f "$screenshots_dir/$filename" ]] && printf '%s\n' "$filename"
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
  elif [[ "$identity_flag" == "prompt" ]]; then
    if ! grep -Eqi "${escaped_username}[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+" <<<"$ocr_text"; then
      feedback+=("$filename: ${github_username}@host terminal prompt was not clearly detected (0)")
      continue
    fi
  elif [[ "$identity_flag" == "lab4user" ]]; then
    if ! grep -Eqi "lab4user[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+" <<<"$ocr_text"; then
      feedback+=("$filename: lab4user@host terminal prompt was not clearly detected (0)")
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

# Validate the required workspace files and their expected Lab 4 contents.
# The task creates them in workspace/python_project, while the submission text
# describes them directly under workspace. Accept both documented layouts.
workspace_dir="$submission_dir/workspace"
project_dir="$workspace_dir"
if [[ -d "$workspace_dir/python_project" ]]; then
  project_dir="$workspace_dir/python_project"
fi
workspace_ok=true
workspace_problem=""

if [[ ! -d "$workspace_dir" ]]; then
  workspace_ok=false
  workspace_problem="workspace directory is missing"
elif [[ ! -s "$project_dir/README.md" ]]; then
  workspace_ok=false
  workspace_problem="workspace README.md is missing or empty"
elif ! grep -Fqi "Lab 4 README" "$project_dir/README.md"; then
  workspace_ok=false
  workspace_problem="workspace README.md does not contain the required text"
elif [[ ! -s "$project_dir/main.py" ]]; then
  workspace_ok=false
  workspace_problem="workspace main.py is missing or empty"
elif ! grep -Eqi "print[[:space:]]*\\([[:space:]]*['\"]hello[[:space:]]+lab4['\"][[:space:]]*\\)" "$project_dir/main.py"; then
  workspace_ok=false
  workspace_problem="workspace main.py does not contain the required print statement"
elif [[ ! -s "$project_dir/.env" ]]; then
  workspace_ok=false
  workspace_problem="workspace .env is missing or empty"
elif ! grep -Eqi '^ENV[[:space:]]*=[[:space:]]*lab4[[:space:]]*$' "$project_dir/.env"; then
  workspace_ok=false
  workspace_problem="workspace .env does not contain ENV=lab4"
fi

if [[ "$workspace_ok" == true ]]; then
  passed=$((passed + 1))
  feedback+=("workspace files: passed")
else
  feedback+=("workspace files: $workspace_problem (0)")
fi

# The README requires a non-empty Word report and either a non-empty PDF or a
# separate solution Markdown file. README.md itself is not a solution report.
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

optional_present=0
for optional_file in "${optional_files[@]}"; do
  [[ -f "$screenshots_dir/$optional_file" ]] && optional_present=$((optional_present + 1))
done

required=$((required_screenshots + 2))

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
