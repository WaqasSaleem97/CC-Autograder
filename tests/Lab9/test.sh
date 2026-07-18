#!/usr/bin/env bash
set -u

# Grade Lab 09 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab9/test.sh \
#     work/submissions/Student/CC/Labs/Lab09 \
#     10
#
# Manual example:
#   bash tests/Lab9/test.sh /path/to/CC/Labs/Lab09 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab09/screenshots"
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
#   none      - no account-name requirement (browser or local desktop evidence)
#   codespace - GitHub username, /workspaces path, or Codespaces context required
#   ec2       - an ec2-user@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task1_gh_install.png|none|winget[[:space:]]+install;;github[.]cli;;(successfully[[:space:]]+installed|installed|github[[:space:]]+cli|gh[[:space:]]+version)
task1_gh_auth_login.png|none|gh[[:space:]]+auth[[:space:]]+login;;(logged[[:space:]]+in|authentication[[:space:]]+complete|successfully[[:space:]]+authenticated|github[.]com);;(codespace|codespaces)
task1_codespace_list.png|none|gh[[:space:]]+codespace[[:space:]]+list;;(name|repository|state|available|codespace)
task1_codespace_ssh_connected.png|codespace|gh[[:space:]]+codespace[[:space:]]+ssh;;(codespace|/workspaces/|github)
task2_aws_install_and_version.png|codespace|awscliv2[.]zip;;(curl|awscli[.]amazonaws[.]com);;unzip;;aws[[:space:]]+--version;;aws-cli/2
task2_aws_configure_and_files.png|codespace|aws[[:space:]]+configure;;([.]aws/credentials|aws_access_key_id);;([.]aws/config|region);;aws_secret_access_key;;(me-central-1|json)
task2_aws_get_caller_identity.png|codespace|aws[[:space:]]+sts[[:space:]]+get-caller-identity;;userid;;account;;arn:aws:(iam|sts)
task3_create_security_group_output.png|codespace|aws[[:space:]]+ec2[[:space:]]+create-security-group;;mysecuritygroup;;vpc-[0-9a-z]+;;sg-[0-9a-z]+
task3_describe_sg_before_ingress.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-security-groups;;(mysecuritygroup|sg-[0-9a-z]+);;(ippermissions|groupid|groupname)
task3_codespace_public_ip.png|codespace|curl[[:space:]]+icanhazip[.]com;;[0-9]{1,3}([.][0-9]{1,3}){3}
task3_authorize_ssh_and_describe.png|codespace|authorize-security-group-ingress;;sg-[0-9a-z]+;;(--port[[:space:]]+22|fromport.*22);;/32;;describe-security-groups
task3_authorize_http_and_describe.png|codespace|authorize-security-group-ingress;;sg-[0-9a-z]+;;(fromport|--port).*80;;ippermissions;;/32
task3_describe_sg_final.png|codespace|describe-security-groups;;sg-[0-9a-z]+;;(fromport|toport);;22;;80;;/32
task4_create_keypair_output.png|codespace|aws[[:space:]]+ec2[[:space:]]+create-key-pair;;myed25519key;;ed25519;;myed25519key[.]pem;;ls[[:space:]]+-l
task4_describe_keypairs.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-key-pairs;;myed25519key;;(ed25519|keyfingerprint|keypairid)
task4_run_instances_output.png|codespace|aws[[:space:]]+ec2[[:space:]]+run-instances;;ami-[0-9a-z]+;;t3[.]micro;;myed25519key;;sg-[0-9a-z]+;;subnet-[0-9a-z]+;;myserver;;i-[0-9a-z]+
task4_describe_instances_public_ip.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-instances;;instanceid;;publicipaddress;;i-[0-9a-z]+;;[0-9]{1,3}([.][0-9]{1,3}){3}
task4_ssh_permission_error_and_fix.png|ec2|ssh[[:space:]]+-i[[:space:]]+.*myed25519key[.]pem;;permissions[[:space:]]+0644;;too[[:space:]]+open;;chmod[[:space:]]+400;;ec2-user@
task4_stop_start_terminate_commands.png|codespace|aws[[:space:]]+ec2[[:space:]]+stop-instances;;aws[[:space:]]+ec2[[:space:]]+start-instances;;i-[0-9a-z]+;;(stopping|stopped|pending|running|currentstate|previousstate);;(terminate-instances|do[[:space:]]+not[[:space:]]+run|don't[[:space:]]+run)
task5_describe_security_groups.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-security-groups;;(groupid|groupname|ippermissions);;sg-[0-9a-z]+
task5_describe_vpcs.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-vpcs;;vpcid;;cidrblock;;vpc-[0-9a-z]+
task5_describe_subnets.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-subnets;;subnetid;;vpcid;;availabilityzone
task5_describe_instances.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-instances;;instanceid;;instancetype;;state
task5_describe_regions.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-regions;;regionname;;endpoint
task5_describe_availability_zones.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-availability-zones;;zonename;;regionname;;state
task6_create_group_and_user.png|codespace|create-group;;mygroupcli;;get-group;;create-user;;myusercli;;get-user;;arn:aws:iam
task6_add_user_to_group_and_verify.png|codespace|add-user-to-group;;myusercli;;mygroupcli;;get-group
task6_policy_list_and_attach.png|codespace|list-policies;;amazonec2fullaccess;;arn:aws:iam::aws:policy;;attach-group-policy;;list-attached-group-policies;;mygroupcli
task6_create_login_profile_and_signin.png|none|create-login-profile;;myusercli;;password-reset-required;;iamuserchangepassword;;(attach-group-policy|detach-group-policy|sign[[:space:]]+in|console)
task6_create_access_key_output.png|codespace|create-access-key;;myusercli;;list-access-keys;;(status|active|accesskeymetadata)
task6_env_exports_and_get_user_error.png|codespace|export[[:space:]]+aws_access_key_id;;export[[:space:]]+aws_secret_access_key;;printenv.*grep.*aws_;;get-user;;myusercli;;(accessdenied|not[[:space:]]+authorized|error)
task6_after_logout_and_get_user_success.png|codespace|aws[[:space:]]+iam[[:space:]]+get-user;;myusercli;;(arn|createdate|userid)
task7_filter_by_tag_public_ip.png|codespace|describe-instances;;--filters;;tag:name;;myserver;;publicipaddress;;[0-9]{1,3}([.][0-9]{1,3}){3}
task7_filter_by_instance_type.png|codespace|describe-instances;;instance-type;;t3[.]micro;;instanceid;;i-[0-9a-z]+
task7_filter_by_subnet.png|codespace|describe-instances;;subnet-id;;subnet-[0-9a-z]+;;instanceid;;i-[0-9a-z]+
task7_filter_by_vpc.png|codespace|describe-instances;;vpc-id;;vpc-[0-9a-z]+;;instanceid;;i-[0-9a-z]+
task8_query_table_instances_name_ip.png|codespace|describe-instances;;instanceid;;publicipaddress;;tags;;myserver;;--output[[:space:]]+table
task8_query_table_instance_state.png|codespace|describe-instances;;instanceid;;state[.]name;;--output[[:space:]]+table;;(running|stopped|pending|terminated)
task8_query_table_instance_type_az.png|codespace|describe-instances;;instanceid;;instancetype;;availabilityzone;;--output[[:space:]]+table;;t3[.]micro
cleanup_terminate_instance.png|codespace|aws[[:space:]]+ec2[[:space:]]+terminate-instances;;i-[0-9a-z]+;;(shutting-down|terminated|currentstate|previousstate)
cleanup_delete_volumes_snapshots.png|none|(volumes|snapshots);;(delete|deleted|no[[:space:]]+volumes|no[[:space:]]+snapshots|0[[:space:]]+volumes|0[[:space:]]+snapshots)
cleanup_delete_security_group_and_keypair.png|codespace|delete-security-group;;sg-[0-9a-z]+;;delete-key-pair;;myed25519key
cleanup_iam_users_deleted.png|codespace|delete-access-key;;delete-login-profile;;remove-user-from-group;;delete-user;;myusercli;;detach-group-policy;;delete-group;;mygroupcli
cleanup_summary.png|none|(billing|cost|resource[[:space:]]+groups|resources);;(no[[:space:]]+active|no[[:space:]]+resources|0[.]00|no[[:space:]]+recent[[:space:]]+charges|zero)
EOF

required=${#criteria[@]}

# This screenshot is explicitly optional in the Lab09 instructions and is not
# scored because deleting the key before launching the instance breaks Task 4.
optional_files=(
  task4_delete_keypair_optional.png
)

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab9-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab9-duplicate-images-${duplicate_key}.tsv"

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

  # Reject clear exposure of private-key material, AWS credentials, or GitHub
  # personal access tokens. Generic field labels are allowed when their actual
  # values are hidden or visibly redacted.
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,})' <<<"$ocr_text"; then
    feedback+=("$filename: sensitive credential material is visible (0)")
    continue
  fi

  identity_pattern=""
  identity_message=""
  case "$identity_flag" in
    codespace)
      identity_pattern="((^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)|/workspaces/|codespaces?)"
      identity_message="GitHub username or Codespaces workspace context was not clearly detected"
      ;;
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

optional_present=0
for optional_file in "${optional_files[@]}"; do
  [[ -f "$screenshots_dir/$optional_file" ]] && optional_present=$((optional_present + 1))
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

summary="Passed $passed/$required Lab 09 required screenshot checks. Optional screenshots present: $optional_present/${#optional_files[@]} (not scored). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
