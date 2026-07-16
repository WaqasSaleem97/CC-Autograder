#!/usr/bin/env bash
set -u

# Grade Lab 07 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab7/test.sh \
#     work/submissions/Student/CC/Labs/Lab07 \
#     10
#
# Manual example:
#   bash tests/Lab7/test.sh /path/to/CC/Labs/Lab07 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab07/screenshots"
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
escaped_username="$(printf '%s' "$normalized_username" | sed 's/[][\.^$*+?{}|()]/\\&/g')"

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none     - no account-name requirement (for example, Windows-only evidence)
#   username - GitHub username must appear somewhere in the screenshot
#   prompt   - <GitHub username>@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task1_printenv_all.png|prompt|(^|[[:space:]])path=;;(^|[[:space:]])home=;;(^|[[:space:]])user=
task1_grep_shell_home_user.png|prompt|(shell=|/bin/(bash|sh));;home=;;user=
task2_exports_all.png|prompt|export[[:space:]]+db_url;;export[[:space:]]+db_user;;export[[:space:]]+db_password
task2_echoes_all.png|prompt|postgres://db[.]example[.]local:5432/mydb;;labuser;;labpass123
task2_printenv_grep_db.png|prompt|db_url=;;db_user=;;db_password=
task2_after_restart_checks.png|prompt|echo.*db_url;;printenv.*grep.*db_
task3_bashrc_added.png|none|lab[[:space:]]*7[[:space:]]+persistent[[:space:]]+db[[:space:]]+variables;;export[[:space:]]+db_url;;export[[:space:]]+db_user;;export[[:space:]]+db_password
task3_source_and_verification.png|prompt|source[[:space:]]+.*[.]bashrc;;postgres://db[.]example[.]local:5432/mydb;;labuser;;labpass123;;printenv.*grep.*db_
task3_after_restart_persistent.png|prompt|echo.*db_url;;postgres://db[.]example[.]local:5432/mydb;;printenv.*grep.*db_
task4_etc_environment_before.png|prompt|(cat|vim|nano).*/etc/environment;;(path=|class=|/usr/)
task4_echo_path_before.png|prompt|echo.*path;;/usr/(local/)?(s)?bin
task4_etc_environment_edit_vim.png|none|class=.*cc-
task4_etc_environment_after.png|prompt|(cat|vim|nano).*/etc/environment;;class=.*cc-
task4_echo_class_and_path.png|prompt|echo.*class;;cc-;;echo.*path;;/usr/(local/)?(s)?bin
task4_welcome_create_and_chmod.png|prompt|(cat|tee).*(~/|/home/.*/)?welcome;;#![[:space:]]*/bin/bash;;welcome[[:space:]]+to[[:space:]]+cloud[[:space:]]+computing;;chmod[[:space:]]+[+]x;;ls[[:space:]]+-l
task4_welcome_run_dot.png|prompt|[.]/welcome;;welcome[[:space:]]+to[[:space:]]+cloud[[:space:]]+computing
task4_bashrc_path_line.png|none|path=.*[$]path.*:~
task4_bashrc_source_and_welcome.png|prompt|source[[:space:]]+.*[.]bashrc;;welcome[[:space:]]+to[[:space:]]+cloud[[:space:]]+computing
task5_ufw_enable_and_status.png|prompt|ufw[[:space:]]+enable;;ufw[[:space:]]+status[[:space:]]+verbose;;status:[[:space:]]+active
task5_ufw_deny_22_and_status.png|prompt|ufw[[:space:]]+deny[[:space:]]+22/tcp;;ufw[[:space:]]+status[[:space:]]+numbered;;22/tcp;;deny
task5_ssh_attempt_blocked.png|none|ssh[[:space:]]+[^[:space:]]+@[^[:space:]]+;;(timed[[:space:]]+out|timeout|refused|failed|unreachable|connection[[:space:]]+(closed|reset))
task5_ufw_allow_reload_status.png|prompt|ufw[[:space:]]+allow[[:space:]]+22/tcp;;ufw[[:space:]]+reload;;ufw[[:space:]]+status;;22/tcp;;allow
task5_ssh_success_after_allow.png|prompt|ssh[[:space:]]+[^[:space:]]+@[^[:space:]]+
task6_windows_sshkey_and_list.png|none|ssh-keygen;;ed25519;;id_lab7;;id_lab7[.]pub
task6_windows_public_key.png|none|ssh-ed25519;;lab_key
task6_windows_known_hosts_cleared_and_empty.png|none|(clear-content|type[[:space:]]+nul|truncate|rm);;known_hosts
task6_windows_ssh_accept_hostkey_and_login.png|prompt|(authenticity|fingerprint|continue[[:space:]]+connecting|permanently[[:space:]]+added|yes)
task6_windows_known_hosts_after_connect.png|none|known_hosts;;(ssh-ed25519|ssh-rsa|ecdsa|sha256|[a-z0-9/+]{20})
task6_server_clear_authorized_keys.png|prompt|mkdir[[:space:]]+-p[[:space:]]+.*[.]ssh;;chmod[[:space:]]+700;;authorized_keys;;chmod[[:space:]]+600
task6_server_add_key_and_show.png|prompt|ssh-ed25519;;authorized_keys;;chmod[[:space:]]+600
task6_ssh_passwordless_login.png|prompt|ssh[[:space:]]+[^[:space:]]+@[^[:space:]]+
task6_ssh_with_identity_file.png|prompt|ssh[[:space:]]+-i[[:space:]]+.*id_lab7;;[^[:space:]]+@[^[:space:]]+
EE_q1_audit_generation.png|prompt|environment-audit[.]txt;;(date|time);;(whoami|user);;hostname;;path
EE_q1_audit_report.png|prompt|environment-audit[.]txt;;shell;;home;;lang;;path;;(hostname|user)
EE_q1_sensitive_names_only.png|prompt|(password|pass|token|secret|key);;(grep|awk|sed|cut);;environment-audit[.]txt
EE_q2_unexported_scope.png|prompt|app_mode;;staging;;(printenv|env);;(bash|child)
EE_q2_exported_scope.png|prompt|export[[:space:]]+app_mode;;staging;;(printenv|env);;(bash|child)
EE_q2_unset_cleanup.png|prompt|unset[[:space:]]+app_mode;;(printenv|env);;(bash|child)
EE_q3_user_persistence_config.png|none|user_notice;;lab07-[0-9]{4}-[a-z]{2,4}-[0-9]{1,3}
EE_q3_system_scope_config.png|none|department;;computer[[:space:]]+science;;/etc/environment
EE_q3_owner_fresh_login.png|prompt|user_notice;;lab07-[0-9]{4}-[a-z]{2,4}-[0-9]{1,3};;department;;computer[[:space:]]+science
EE_q3_other_user_scope.png|none|department;;computer[[:space:]]+science;;user_notice
EE_q3_configuration_cleanup.png|prompt|user_notice;;department;;(grep|sed|unset|[.]bashrc|/etc/environment)
EE_q4_initial_command_failure.png|prompt|syscheck;;lab7-tools;;(command[[:space:]]+not[[:space:]]+found|permission[[:space:]]+denied|cannot[[:space:]]+execute)
EE_q4_tool_and_path_fix.png|none|syscheck;;lab7-tools;;chmod;;path
EE_q4_fresh_session_success.png|prompt|/tmp;;syscheck;;(command[[:space:]]+-v|which|type);;(hostname|user|working[[:space:]]+directory|date)
EE_q5_service_and_listener.png|prompt|index[.]html;;8080;;(listen|http[.]server|python);;(^|[^[:alnum:]-])GITHUB_USERNAME_PLACEHOLDER([^[:alnum:]-]|$)
EE_q5_client_baseline_success.png|username|8080;;([0-9]{4}-[a-z]{2,4}-[0-9]{1,3}|200[[:space:]]+ok|http)
EE_q5_ufw_block_rule.png|prompt|ufw;;8080;;deny;;(status[[:space:]]+numbered|\[[0-9]+\]);;(22/tcp|ssh)
EE_q5_client_blocked.png|none|8080;;(timed[[:space:]]+out|timeout|refused|failed|unreachable|unable[[:space:]]+to[[:space:]]+connect)
EE_q5_source_restricted_rule.png|prompt|ufw;;8080;;allow;;(from|[0-9]{1,3}([.][0-9]{1,3}){3});;(22/tcp|ssh)
EE_q5_client_restricted_success.png|username|8080;;([0-9]{4}-[a-z]{2,4}-[0-9]{1,3}|200[[:space:]]+ok|http)
EE_q5_firewall_cleanup.png|prompt|8080;;(delete|removed);;(ufw|status)
EE_q6_client_key_fingerprint.png|username|id_lab7_exam;;(sha256|fingerprint);;ed25519
EE_q6_server_key_permissions.png|prompt|authorized_keys;;([.]ssh|700|drwx);;(600|rw-------);;(lab7-exam|ssh-ed25519)
EE_q6_fingerprint_match.png|username|(sha256|fingerprint);;(id_lab7_exam|lab7-exam);;ed25519
EE_q6_explicit_key_success.png|prompt|ssh;;id_lab7_exam;;(identitiesonly|identityfile|-i);;(batchmode|passwordauthentication|password[[:space:]]+prompt)
EE_q6_unregistered_key_failure.png|none|ssh;;(permission[[:space:]]+denied|publickey|authentication[[:space:]]+failed);;(identity|id_)
EE_q6_exam_key_cleanup.png|none|authorized_keys;;lab7-exam;;(remove|sed|grep);;(id_lab7|ssh-ed25519)
EOF

# Replace the username placeholder used by the Q5 local-page criterion without
# allowing the username to change the structure of any other rule.
for index in "${!criteria[@]}"; do
  criteria[$index]="${criteria[$index]//GITHUB_USERNAME_PLACEHOLDER/$escaped_username}"
done

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab7-ocr-${normalized_username}.XXXXXX")"
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
# all students selected in this workflow. Every matching copy receives zero.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab7-duplicate-images-${duplicate_key}.tsv"

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

  # Pillow verifies that the file is a decodable image. There is intentionally
  # no minimum-width, minimum-height, or file-size grading rule.
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

summary="Passed $passed/$required Lab 07 screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
