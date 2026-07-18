#!/usr/bin/env bash
set -u

# Grade Lab 08 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab8/test.sh \
#     work/submissions/Student/CC/Labs/Lab08 \
#     10
#
# Manual example:
#   bash tests/Lab8/test.sh /path/to/CC/Labs/Lab08 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab08/screenshots"
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
#   none - no account-name requirement (AWS console or Windows evidence)
#   ec2  - an ec2-user@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task1_open_signup_page.png|none|(create[[:space:]]+.*aws[[:space:]]+account|sign[[:space:]]+up[[:space:]]+for[[:space:]]+aws|aws[[:space:]]+account);;(email|root[[:space:]]+user)
task1_signed_up_confirmation.png|none|(congratulations|registration|sign-up|account[[:space:]]+(created|ready)|thank[[:space:]]+you|complete[[:space:]]+sign[[:space:]]+up|welcome.*aws|being[[:space:]]+activated|activation);;(aws|payment|support[[:space:]]+plan|account)
task1_root_signed_in.png|none|(console[[:space:]]+home|aws[[:space:]]+management[[:space:]]+console);;(root|account|@[a-z0-9])
task1_enable_region_me-central-1.png|none|(me-central-1|middle[[:space:]]+east.*uae|uae)
task1_summary.png|none|(root|account);;(me-central-1|middle[[:space:]]+east.*uae|uae);;(console|aws)
task2_open_iam_console.png|none|(identity[[:space:]]+and[[:space:]]+access[[:space:]]+management|iam);;(dashboard|access[[:space:]]+management|users)
task2_admin_create_confirmation.png|none|admin;;((user|users).*(created|success)|create[[:space:]]+user|view[[:space:]]+user);;(administratoraccess|permissions|console[[:space:]]+access|sign-in[[:space:]]+url)
task2_admin_csv_and_signin_url.png|none|(admin|credentials);;([.]csv|sign-in[[:space:]]+url|signin[[:space:]]+url|console[[:space:]]+sign-in)
task2_admin_console_after_login.png|none|admin;;(console[[:space:]]+home|aws[[:space:]]+management[[:space:]]+console|account)
task2_create_lab8user_and_csv.png|none|lab8user;;((user|users).*(created|success)|download.*[.]csv|console[[:space:]]+password|view[[:space:]]+user)
task2_lab8user_csv_saved.png|none|lab8user;;([.]csv|credentials)
task2_lab8user_logged_in.png|none|lab8user;;(console[[:space:]]+home|aws[[:space:]]+management[[:space:]]+console|account)
task2_summary.png|none|admin;;lab8user;;(users|user[[:space:]]+name|iam)
task3_open_vpc_console.png|none|(virtual[[:space:]]+private[[:space:]]+cloud|vpc);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task3_vpcs_list.png|none|(your[[:space:]]+vpcs|vpcs);;(vpc[[:space:]]+id|default[[:space:]]+vpc|is[[:space:]]+default);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task3_subnets_list.png|none|subnets;;(subnet[[:space:]]+id|availability[[:space:]]+zone|default[[:space:]]+subnet);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task3_route_tables_list.png|none|route[[:space:]]+tables;;(route[[:space:]]+table[[:space:]]+id|main|routes);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task3_network_acls_list.png|none|(network[[:space:]]+acls|network[[:space:]]+access[[:space:]]+control[[:space:]]+lists);;(network[[:space:]]+acl[[:space:]]+id|default|associated);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task3_summary.png|none|vpcs;;subnets;;route[[:space:]]+tables;;network[[:space:]]+acls;;(me-central-1|middle[[:space:]]+east.*uae|uae)
task4_open_ec2_console.png|none|(ec2|elastic[[:space:]]+compute[[:space:]]+cloud);;(instances|resources);;(me-central-1|middle[[:space:]]+east.*uae|uae)
task4_launch_instance_config.png|none|lab8machine;;amazon[[:space:]]+linux;;t[23][.]micro;;lab8securitygroup;;lab8key
task4_keypair_download.png|none|lab8key[.]pem
task4_instance_running_console.png|none|lab8machine;;running;;(public[[:space:]]+ipv4|public[[:space:]]+ip|[0-9]{1,3}([.][0-9]{1,3}){3})
task4_ssh_from_windows_to_ec2.png|ec2|ssh[[:space:]]+-i[[:space:]]+.*lab8key[.]pem;;ec2-user@([0-9]{1,3}([.][0-9]{1,3}){3}|[[:alnum:].-]+)
task4_ec2_install_docker_compose_started.png|ec2|yum[[:space:]]+(update|install);;docker;;docker-compose;;(curl|cli-plugins);;systemctl[[:space:]]+start[[:space:]]+docker
task4_vim_compose_yaml_paste.png|none|(compose[.]yaml|services:);;(gitea|gitea/gitea);;(image:|ports:|volumes:)
task4_compose_yaml_saved_ls.png|ec2|ls[[:space:]]+-l;;compose[.]yaml
task4_usermod_and_groups_before_after.png|ec2|usermod[[:space:]]+-aG[[:space:]]+docker;;groups;;docker;;ssh[[:space:]]+-i[[:space:]]+.*lab8key[.]pem
task4_docker_compose_up.png|ec2|docker[[:space:]]+compose[[:space:]]+up[[:space:]]+-d;;(created|started|running|pulling|container)
task4_security_group_allow_3000.png|none|lab8securitygroup;;3000;;(custom[[:space:]]+tcp|tcp);;0[.]0[.]0[.]0/0;;(ssh|22)
task4_gitea_install_page.png|none|gitea;;(initial[[:space:]]+configuration|database[[:space:]]+settings|install[[:space:]]+gitea|general[[:space:]]+settings);;(3000|http)
task4_gitea_create_repo.png|none|gitea;;(repository|repositories);;(code|issues|commits|new[[:space:]]+repository)
task4_summary.png|none|lab8machine;;running;;(3000|lab8securitygroup);;gitea
cleanup_terminate_instance.png|none|lab8machine;;(terminate|terminating|terminated)
cleanup_delete_volumes_snapshots.png|none|(volumes|snapshots);;(delete|deleted|no[[:space:]]+volumes|no[[:space:]]+snapshots|0[[:space:]]+volumes|0[[:space:]]+snapshots)
cleanup_delete_security_group_and_keypair.png|none|(lab8securitygroup|security[[:space:]]+groups);;(lab8key|key[[:space:]]+pairs);;(delete|deleted|no[[:space:]]+security[[:space:]]+groups|no[[:space:]]+key[[:space:]]+pairs)
cleanup_iam_users_deleted.png|none|(iam|users);;(delete|deleted|no[[:space:]]+users|lab8user|admin)
cleanup_summary.png|none|(billing|cost|resource[[:space:]]+groups|resources);;(no[[:space:]]+active|no[[:space:]]+resources|0[.]00|no[[:space:]]+recent[[:space:]]+charges|zero)
EOF

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab8-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab8-duplicate-images-${duplicate_key}.tsv"

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

  # Reject clear exposure of private-key material or an AWS access-key ID.
  # Generic words such as "password" are not rejected because AWS pages may
  # display field labels even when the actual value is correctly hidden.
  if grep -Eqi -- '(begin.*private[[:space:]]+key|akia[0-9a-z]{16})' <<<"$ocr_text"; then
    feedback+=("$filename: sensitive credential material is visible (0)")
    continue
  fi

  identity_pattern=""
  identity_message=""
  case "$identity_flag" in
    ec2)
      identity_pattern="ec2-user[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="ec2-user@host terminal prompt was not clearly detected"
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

summary="Passed $passed/$required Lab 08 screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
