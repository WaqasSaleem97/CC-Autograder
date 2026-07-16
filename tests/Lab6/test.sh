#!/usr/bin/env bash
set -u

# Grade Lab 6 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab6/test.sh \
#     work/submissions/Student/CC/Labs/Lab06 \
#     10
#
# Manual example:
#   bash tests/Lab6/test.sh /path/to/CC/Labs/Lab06 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab06/screenshots"
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
#   none     - no account-name requirement
#   username - GitHub username must appear somewhere
#   prompt   - <GitHub username>@<host> terminal prompt must appear
#   root     - root@<host> terminal prompt must appear
#   student  - Student@student@<host> terminal prompt must appear
#   scooby   - Scooby@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task1_set_root_password.png|prompt|sudo[[:space:]]+passwd[[:space:]]+root;;(password[[:space:]]+updated[[:space:]]+successfully|new[[:space:]]+password|retype[[:space:]]+new[[:space:]]+password)
task1_su_root.png|root|su[[:space:]]+-;;whoami;;root;;uid=0
task1_exit_to_user.png|prompt|exit;;whoami
task2_adduser_tom.png|none|(adduser|adding[[:space:]]+user);;tom;;(/home/tom|new[[:space:]]+password|user[[:space:]]+information)
task2_verify_passwd.png|prompt|cat[[:space:]]+/etc/passwd;;tom:.*:/home/tom
task2_verify_group.png|prompt|cat[[:space:]]+/etc/group;;tom:
task2_verify_shadow.png|prompt|cat[[:space:]]+/etc/shadow;;tom:
task3_groupadd.png|prompt|groupadd[[:space:]]+developer;;groupadd[[:space:]]+devops;;groupadd[[:space:]]+designer;;(developer:|devops:|designer:)
task3_change_primary_group.png|prompt|usermod[[:space:]]+-g[[:space:]]+designer[[:space:]]+tom;;id[[:space:]]+tom;;designer
task3_add_secondary_groups.png|prompt|usermod[[:space:]]+-aG;;developer,devops;;tom;;(id|groups)[[:space:]]+tom
task3_reset_secondary_groups.png|prompt|usermod[[:space:]]+-G[[:space:]]+tom[[:space:]]+tom;;(id|groups)[[:space:]]+tom
task4_add_users.png|none|adduser[[:space:]]+Jerry;;useradd[[:space:]]+Scooby;;(Jerry|Scooby)
task4_scooby_su_auth_failure.png|prompt|su[[:space:]]+-[[:space:]]+Scooby;;(authentication[[:space:]]+failure|su:[[:space:]]+failure|incorrect[[:space:]]+password)
task4_set_password_scooby.png|prompt|passwd[[:space:]]+Scooby;;(password[[:space:]]+updated[[:space:]]+successfully|new[[:space:]]+password|retype[[:space:]]+new[[:space:]]+password)
task4_scooby_su_no_home.png|scooby|su[[:space:]]+-[[:space:]]+Scooby;;(no[[:space:]]+directory|cannot[[:space:]]+change[[:space:]]+directory|HOME=/)
task4_scooby_no_home.png|prompt|cat[[:space:]]+/etc/passwd;;Scooby:;;ls[[:space:]]+-ld[[:space:]]+/home/Scooby;;(no[[:space:]]+such[[:space:]]+file|cannot[[:space:]]+access)
task4_scooby_create_home.png|prompt|mkdir[[:space:]]+-p[[:space:]]+/home/Scooby;;chown[[:space:]]+Scooby:Scooby;;chmod[[:space:]]+750;;ls[[:space:]]+-ld
task4_scooby_login_success.png|scooby|su[[:space:]]+-[[:space:]]+Scooby;;pwd;;/home/Scooby;;ls[[:space:]]+-la
task4_verify_users.png|prompt|cat[[:space:]]+/etc/passwd;;(Jerry:|Scooby:);;(/bin/sh|/bin/bash)
task4_shell_switching.png|scooby|usermod[[:space:]]+-s[[:space:]]+/bin/bash[[:space:]]+Scooby;;su[[:space:]]+-[[:space:]]+Scooby
task4_add_groups.png|prompt|(addgroup[[:space:]]+jolly|groupadd[[:space:]]+anime);;(jolly|anime)
task4_verify_groups.png|prompt|cat[[:space:]]+/etc/group;;jolly:;;anime:
task4_delete_groups.png|prompt|(delgroup[[:space:]]+jolly|groupdel[[:space:]]+anime);;cat[[:space:]]+/etc/group
task4_delete_users.png|prompt|(deluser[[:space:]]+--remove-home[[:space:]]+Jerry|userdel[[:space:]]+-r[[:space:]]+Scooby);;cat[[:space:]]+/etc/passwd
task5_create_student.png|none|(adduser|adding[[:space:]]+user);;Student;;(/home/Student|new[[:space:]]+password|user[[:space:]]+information)
task5_create_files.png|student|su[[:space:]]+-[[:space:]]+Student;;touch[[:space:]]+file[1l];;mkdir[[:space:]]+-p[[:space:]]+dir1;;file2;;ls[[:space:]]+-l
task5_chown_file1.png|student|chown[[:space:]]+tom[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l];;tom
task5_chgrp_file1.png|student|chgrp[[:space:]]+devops[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l];;devops
task5_file_types.png|student|ls[[:space:]]+-l;;/dev/null;;file[[:space:]]+file[1l][[:space:]]+dir1[[:space:]]+/dev/null;;(directory|empty|character[[:space:]]+special)
task5_exit_student.png|prompt|exit
task6_su_student.png|student|su[[:space:]]+-[[:space:]]+Student;;cd[[:space:]]+~;;ls[[:space:]]+-l[[:space:]]+file[1l]
task6_chmod_remove_rwx.png|student|chmod[[:space:]]+-rwx[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task6_chmod_add_r.png|student|chmod[[:space:]]+\+r[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task6_chmod_u_plus_x.png|student|chmod[[:space:]]+u\+x[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task6_chmod_ug_plus_w.png|student|chmod[[:space:]]+ug\+w[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task6_chmod_ugo_minus_rwx.png|student|chmod[[:space:]]+ugo-rwx[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task7_student_context.png|student|su[[:space:]]+-[[:space:]]+Student;;ls[[:space:]]+-l[[:space:]]+file[1l]
task7_chmod_set_all_rwx.png|student|chmod[[:space:]]+u=rwx,g=rwx,o=rwx[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task7_remove_exec_go.png|student|chmod[[:space:]]+g=rw,o=rw[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task7_remove_all_perms.png|student|chmod[[:space:]]+u=,g=,o=[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_student_context.png|student|su[[:space:]]+-[[:space:]]+Student;;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_777.png|student|chmod[[:space:]]+777[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_700.png|student|chmod[[:space:]]+700[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_744.png|student|chmod[[:space:]]+744[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_640.png|student|chmod[[:space:]]+640[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_664.png|student|chmod[[:space:]]+664[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_775.png|student|chmod[[:space:]]+775[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task8_chmod_750.png|student|chmod[[:space:]]+750[[:space:]]+file[1l];;ls[[:space:]]+-l[[:space:]]+file[1l]
task9_grep_less.png|none|(cat[[:space:]]+/var/log/syslog[[:space:]]*\|[[:space:]]*less|journalctl[[:space:]]*\|[[:space:]]*less|syslog);;(less|syslog|no[[:space:]]+such[[:space:]]+file)
task9_grep_more.png|none|cat[[:space:]]+/var/log/syslog[[:space:]]*\|[[:space:]]*more;;(syslog|--More--|no[[:space:]]+such[[:space:]]+file)
task9_grep_head.png|prompt|grep[[:space:]]+-E;;fail\|error;;/var/log/syslog;;head
task9_redirect_overwrite.png|prompt|grep[[:space:]]+-i[[:space:]]+systemd;;/var/log/syslog;;>;;syslog_systemd[.]txt
task9_redirect_append.png|prompt|grep[[:space:]]+-i[[:space:]]+network;;>>;;syslog_systemd[.]txt;;cat;;(systemd|network)
task10_b1_vim.png|none|#!/bin/bash;;setup[.]sh
task10_b1_run.png|student|chmod[[:space:]]+\+x[[:space:]]+setup[.]sh;;[.]/setup[.]sh
task10_b2_vim.png|none|var1=.*Hello[[:space:]]+from[[:space:]]+Lab[[:space:]]+6;;echo.*var1
task10_b2_run.png|student|[.]/setup[.]sh;;var1:.*Hello[[:space:]]+from[[:space:]]+Lab[[:space:]]+6
task10_b3_vim.png|none|allFiles=.*ls[[:space:]]+-l;;echo.*allFiles
task10_b3_run.png|student|[.]/setup[.]sh;;allFiles.*ls[[:space:]]+-l;;(setup[.]sh|file1|dir1|total)
task10_b4_vim.png|none|if[[:space:]]+\[[[:space:]]+-d.*dir1;;mkdir[[:space:]]+-p;;Directory[[:space:]]+dir1
task10_b4_run.png|student|[.]/setup[.]sh;;Directory[[:space:]]+dir1[[:space:]]+(exists|does[[:space:]]+not[[:space:]]+exist|created)
task10_b5_vim.png|none|if[[:space:]]+\[[[:space:]]+-f.*dir1/file2;;touch.*dir1/file2;;chmod[[:space:]]+a-rwx
task10_b5_run.png|student|[.]/setup[.]sh;;file2[[:space:]]+(already[[:space:]]+exists|does[[:space:]]+not[[:space:]]+exist|created)
task10_b6_vim.png|none|f=.*dir1/file2;;!.*-r;;!.*-w;;!.*-x;;chmod[[:space:]]+u\+[rwx];;Final[[:space:]]+permissions
task10_b6_run.png|student|[.]/setup[.]sh;;Final[[:space:]]+permissions;;dir1/file2
task11_b0_vim.png|none|#!/bin/bash;;num=[$]1;;str=[$]2
task11_b0_run.png|student|[.]/setup[.]sh[[:space:]]+10[[:space:]]+Student
task11_b1_vim.png|none|num.*-eq[[:space:]]+10;;equal[[:space:]]+to[[:space:]]+10
task11_b1_run.png|student|[.]/setup[.]sh;;10[[:space:]]+Student;;7[[:space:]]+Student;;(equal|NOT[[:space:]]+equal)
task11_b2_vim.png|none|num.*-ne[[:space:]]+10;;not[[:space:]]+equal[[:space:]]+to[[:space:]]+10
task11_b2_run.png|student|[.]/setup[.]sh;;7[[:space:]]+Student;;10[[:space:]]+Student;;(not[[:space:]]+equal|equal)
task11_b3_vim.png|none|num.*-gt[[:space:]]+10;;greater[[:space:]]+than[[:space:]]+10
task11_b3_run.png|student|[.]/setup[.]sh;;12[[:space:]]+Student;;9[[:space:]]+Student;;greater[[:space:]]+than
task11_b4_vim.png|none|num.*-lt[[:space:]]+10;;less[[:space:]]+than[[:space:]]+10
task11_b4_run.png|student|[.]/setup[.]sh;;5[[:space:]]+Student;;11[[:space:]]+Student;;less[[:space:]]+than
task11_b5_vim.png|none|num.*-ge[[:space:]]+10;;greater[[:space:]]+than[[:space:]]+or[[:space:]]+equal
task11_b5_run.png|student|[.]/setup[.]sh;;10[[:space:]]+Student;;8[[:space:]]+Student;;greater[[:space:]]+than[[:space:]]+or[[:space:]]+equal
task11_b6_vim.png|none|num.*-le[[:space:]]+10;;less[[:space:]]+than[[:space:]]+or[[:space:]]+equal
task11_b6_run.png|student|[.]/setup[.]sh;;10[[:space:]]+Student;;12[[:space:]]+Student;;less[[:space:]]+than[[:space:]]+or[[:space:]]+equal
task11_b7_vim.png|none|str.*=[[:space:]]*Student;;Second[[:space:]]+argument[[:space:]]+equals
task11_b7_run.png|student|[.]/setup[.]sh;;10[[:space:]]+Student;;10[[:space:]]+Test;;Second[[:space:]]+argument
task11_b8_vim.png|none|str.*!=[[:space:]]*Student;;Second[[:space:]]+argument.*not[[:space:]]+equal
task11_b8_run.png|student|[.]/setup[.]sh;;10[[:space:]]+Test;;10[[:space:]]+Student;;Second[[:space:]]+argument
task11_b9_vim.png|none|-z.*str;;Second[[:space:]]+argument[[:space:]]+is[[:space:]]+empty
task11_b9_run.png|student|[.]/setup[.]sh;;10;;10[[:space:]]+Student;;(empty|not[[:space:]]+empty)
task12_b1_vim.png|none|#!/bin/bash;;printing[[:space:]]+all.*arguments;;[$][*]
task12_b1_run.png|student|[.]/setup[.]sh
task12_b2_vim.png|none|for[[:space:]]+arg[[:space:]]+in[[:space:]]+[$][*];;echo.*Argument
task12_b2_run.png|student|[.]/setup[.]sh;;one;;two;;words;;three;;Argument:
task13_b1_vim.png|none|#!/bin/bash;;setup[.]sh
task13_b1_run.png|student|chmod[[:space:]]+\+x[[:space:]]+setup[.]sh;;[.]/setup[.]sh
task13_b2_vim.png|none|sum=0;;while[[:space:]]+true;;read[[:space:]]+-p;;Total[[:space:]]+Score;;Final[[:space:]]+total
task13_b2_run.png|student|[.]/setup[.]sh;;Total[[:space:]]+Score:[[:space:]]+5;;Total[[:space:]]+Score:[[:space:]]+12;;Final[[:space:]]+total:[[:space:]]+12
task13_b3_vim.png|none|sum_two[[:space:]]*\(\);;while[[:space:]]+true;;Function[[:space:]]+final[[:space:]]+total;;sum_two
task13_b3_run.png|student|[.]/setup[.]sh;;Now[[:space:]]+calling[[:space:]]+sum_two;;Total[[:space:]]+Score:[[:space:]]+3;;Total[[:space:]]+Score:[[:space:]]+7;;Function[[:space:]]+final[[:space:]]+total:[[:space:]]+7
task13_b4_vim.png|none|sum_args[[:space:]]*\(\);;a=[$]1;;b=[$]2;;return.*a[[:space:]]*\+[[:space:]]*b;;result=[$][?]
task13_b4_run.png|student|[.]/setup[.]sh;;sum_args\(3,4\)[[:space:]]+returned:[[:space:]]+7
task14_fork.png|username|(forked[[:space:]]+from|UbuntuMachine);;(code|issues|pull[[:space:]]+requests|actions)
task14_codespace_launch.png|none|(codespace|setting[[:space:]]+up[[:space:]]+your[[:space:]]+codespace|opening[[:space:]]+remote);;UbuntuMachine
task14_start_script_ls.png|none|ls[[:space:]]+-l;;start-desktop[.]sh;;stop-desktop[.]sh
task14_start_run.png|none|[.]/start-desktop[.]sh;;(desktop|vnc|novnc|6080);;(started|running|ready|connect)
task14_ports_view.png|none|6080;;(forwarded[[:space:]]+address|visibility|port|running)
task14_vnc_url.png|none|(vnc[.]html|6080);;(http|https|connect|noVNC)
task14_vnc_password_prompt.png|none|(password|credentials);;(connect|noVNC|VNC)
task14_vnc_desktop.png|none|(applications|desktop|terminal|xfce|ubuntu);;(noVNC|VNC|workspace|files)
task14_stop_run.png|none|[.]/stop-desktop[.]sh;;(desktop|vnc|novnc);;(stopped|stopping|cleanup|killed)
Q1_groups_created.png|none|(groupadd|addgroup);;g1;;g2;;g3
Q1_group_changes.png|none|usermod;;examuser;;g3;;g1,g2
Q1_group_verification.png|none|id[[:space:]]+examuser;;/etc/group;;g1;;g2;;g3
Q2_chown_chgrp.png|none|secret[.]txt;;chown;;examuser;;chgrp;;g1
Q2_symbolic_numeric.png|none|chmod;;secret[.]txt;;(go-rwx|g-rwx,o-rwx|700|600)
Q2_permissions_ls.png|none|ls[[:space:]]+-l;;secret[.]txt;;examuser;;g1
Q3_grep_pipe.png|none|(grep|journalctl);;(error|fail);;head;;20
Q3_redirect_overwrite_append.png|none|errors[.]txt;;>;;>>;;(error|fail)
Q3_pager_view.png|none|(less|more);;errors[.]txt
Q4_step1_var1.png|none|#!/bin/bash;;var1;;echo
Q4_step2_allfiles.png|none|allFiles;;ls[[:space:]]+-l;;echo
Q4_step3_dirfile_checks.png|none|dir1;;file2;;(if[[:space:]]+\[|mkdir|touch);;(permissions|ls[[:space:]]+-l|chmod)
Q5_eq_examples.png|none|num=[$]1;;-eq;;(true|false|equal|NOT[[:space:]]+equal)
Q5_numeric_tests.png|none|-ne;;-gt;;-lt;;-ge;;-le
Q5_string_tests.png|none|str=[$]2;;(=[[:space:]]*Student|equals);;(!=|not[[:space:]]+equal);;-z
Q6_script_forloop_vim.png|none|for[[:space:]]+.*[[:space:]]+in[[:space:]]+.*[$]@;;echo
Q6_forloop_run.png|none|Argument:;;(two[[:space:]]+words|multi-word|quoted);;(one|three)
Q7_while_session.png|none|while;;(Enter[[:space:]]+a[[:space:]]+number|Total[[:space:]]+Score);;(Final[[:space:]]+total|q)
Q7_function_sum.png|none|(sum_args|function);;(result|returned|sum);;[0-9]+
EOF

required_screenshots=${#criteria[@]}

# These screenshots are explicitly alternatives/optional in the README.
optional_files=(
  task9_journalctl_alternative.png
  task14_vnc_connect.png
)

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab6-ocr-${normalized_username}.XXXXXX")"
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

# Build one exact-duplicate index for screenshots with the same task filename
# across all students selected in this workflow. Both copies receive zero.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab6-duplicate-images-${duplicate_key}.tsv"

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

  identity_pattern=""
  identity_message=""
  case "$identity_flag" in
    username)
      identity_pattern="(^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)"
      identity_message="GitHub username was not clearly detected"
      ;;
    prompt)
      identity_pattern="${escaped_username}[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="${github_username}@host terminal prompt was not clearly detected"
      ;;
    root)
      identity_pattern="root[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="root@host terminal prompt was not clearly detected"
      ;;
    student)
      identity_pattern="student[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="Student@host terminal prompt was not clearly detected"
      ;;
    scooby)
      identity_pattern="scooby[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="Scooby@host terminal prompt was not clearly detected"
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

  passed=$((passed + 1))
  feedback+=("$filename: passed")
done

optional_present=0
for optional_file in "${optional_files[@]}"; do
  [[ -f "$screenshots_dir/$optional_file" ]] && optional_present=$((optional_present + 1))
done

# Workspace and report files are marked optional in the submission structure.
word_report_present=false
alternate_report_present=false
if find "$submission_dir" -maxdepth 1 -type f \
  \( -iname '*.doc' -o -iname '*.docx' \) -size +0c -print -quit |
  grep -q .; then
  word_report_present=true
fi
if find "$submission_dir" -maxdepth 1 -type f \
  \( -iname '*.pdf' -o -iname '*.md' \) \
  ! -iname 'README.md' -size +0c -print -quit |
  grep -q .; then
  alternate_report_present=true
fi

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

summary="Passed $passed/$required Lab 6 required checks. Optional screenshots present: $optional_present/${#optional_files[@]} (not scored). Optional reports: Word=$word_report_present, PDF-or-Markdown=$alternate_report_present. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
