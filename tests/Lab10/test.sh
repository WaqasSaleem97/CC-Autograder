#!/usr/bin/env bash
set -u

# Grade Lab 10 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab10/test.sh \
#     work/submissions/Student/CC/Labs/Lab10 \
#     10
#
# Manual example:
#   bash tests/Lab10/test.sh /path/to/CC/Labs/Lab10 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab10/screenshots"
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
readarray -t criteria <<'EOF'
task1_gh_install.png|none|winget[[:space:]]+install;;github[.]cli;;(successfully[[:space:]]+installed|installed|github[[:space:]]+cli|gh[[:space:]]+version)
task1_gh_auth_login.png|none|gh[[:space:]]+auth[[:space:]]+login;;(logged[[:space:]]+in|authentication[[:space:]]+complete|successfully[[:space:]]+authenticated|github[.]com);;(codespace|codespaces)
task1_codespace_list.png|none|gh[[:space:]]+codespace[[:space:]]+list;;(name|repository|state|available|codespace)
task1_codespace_ssh_connected.png|codespace|gh[[:space:]]+codespace[[:space:]]+ssh;;(codespace|/workspaces/|github)
task2_aws_install_and_version.png|codespace|awscliv2[.]zip;;(curl|awscli[.]amazonaws[.]com);;unzip;;aws[[:space:]]+--version;;aws-cli/2
task2_aws_configure_and_files.png|codespace|aws[[:space:]]+configure;;([.]aws/credentials|aws_access_key_id);;([.]aws/config|region);;aws_secret_access_key;;(me-central-1|json)
task2_aws_get_caller_identity.png|codespace|aws[[:space:]]+sts[[:space:]]+get-caller-identity;;userid;;account;;arn:aws:(iam|sts)
task2_terraform_install_and_version.png|codespace|(hashicorp|apt[.]releases[.]hashicorp[.]com);;apt[[:space:]]+install[[:space:]]+terraform;;which[[:space:]]+terraform;;terraform[[:space:]]+--version;;terraform[[:space:]]+v?[0-9]+[.][0-9]+
task2_provider_file_creation.png|none|(vim|vi|nano)[[:space:]]+main[.]tf;;main[.]tf
task2_provider_block.png|none|provider[[:space:]]+"aws";;shared_config_files;;[.]aws/config;;shared_credentials_files;;[.]aws/credentials
task2_terraform_init_output.png|codespace|terraform[[:space:]]+init;;terraform[[:space:]]+has[[:space:]]+been[[:space:]]+successfully[[:space:]]+initialized;;(hashicorp/aws|provider)
task2_terraform_lock_hcl.png|codespace|cat[[:space:]]+[.]terraform[.]lock[.]hcl;;registry[.]terraform[.]io/hashicorp/aws;;(version|constraints|hashes)
task2_terraform_dir_ls.png|codespace|ls[[:space:]]+[.]terraform/?;;providers
task3_main_tf_resource_add.png|none|resource[[:space:]]+"aws_vpc"[[:space:]]+"development_vpc";;10[.]0[.]0[.]0/16;;resource[[:space:]]+"aws_subnet"[[:space:]]+"dev_subnet_1";;10[.]0[.]10[.]0/24;;me-central-1a
task3_terraform_apply_vpc_subnet.png|codespace|terraform[[:space:]]+apply;;aws_vpc[.]development_vpc;;aws_subnet[.]dev_subnet_1;;apply[[:space:]]+complete;;added
task3_aws_cli_verify_subnet.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-subnets;;(--filter|--filters);;subnet-[0-9a-z]+;;(cidrblock|10[.]0[.]10[.]0/24);;availabilityzone
task3_aws_cli_verify_vpc.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-vpcs;;(--filter|--filters);;vpc-[0-9a-z]+;;(cidrblock|10[.]0[.]0[.]0/16)
task4_main_tf_datasource_resource_add.png|none|data[[:space:]]+"aws_vpc"[[:space:]]+"existing_vpc";;default[[:space:]]*=[[:space:]]*true;;resource[[:space:]]+"aws_subnet"[[:space:]]+"dev_subnet_1_existing";;172[.]31[.]48[.]0/24;;me-central-1a
task4_terraform_apply_datasource_resource.png|codespace|terraform[[:space:]]+apply;;aws_subnet[.]dev_subnet_1_existing;;apply[[:space:]]+complete;;(1[[:space:]]+added|added)
task4_terraform_destroy_targeted.png|codespace|terraform[[:space:]]+destroy;;-target=aws_subnet[.]dev_subnet_1_existing;;destroy[[:space:]]+complete
task4_terraform_refresh_state.png|codespace|terraform[[:space:]]+refresh;;(refreshing[[:space:]]+state|refresh[[:space:]]+complete|aws_vpc|aws_subnet)
task4_terraform_apply_after_refresh.png|codespace|terraform[[:space:]]+apply;;aws_subnet[.]dev_subnet_1_existing;;apply[[:space:]]+complete;;added
task4_terraform_destroy_all.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
task4_terraform_plan_output.png|codespace|terraform[[:space:]]+plan;;plan:;;to[[:space:]]+add
task4_terraform_apply_after_destroy.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;aws_vpc[.]development_vpc;;aws_subnet[.]dev_subnet_1
task4_main_tf_tagging.png|none|tags[[:space:]]*=;;name[[:space:]:=]+"development";;vpc_env[[:space:]]*=.*"dev";;name[[:space:]:=]+"subnet-1-dev";;name[[:space:]:=]+"subnet-1-default"
task4_terraform_apply_tagging.png|codespace|terraform[[:space:]]+refresh;;terraform[[:space:]]+apply[[:space:]]+-auto-approve;;apply[[:space:]]+complete;;(changed|updated|in-place)
task4_terraform_plan_remove_tag.png|codespace|terraform[[:space:]]+plan;;vpc_env;;(null|removed|delete|->);;plan:
task4_terraform_apply_remove_tag.png|codespace|terraform[[:space:]]+apply;;vpc_env;;apply[[:space:]]+complete;;(changed|0[[:space:]]+added)
task5_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
task5_terraform_state_file_empty.png|codespace|cat[[:space:]]+terraform[.]tfstate;;"resources"[[:space:]]*:[[:space:]]*\[;;"outputs"[[:space:]]*:[[:space:]]*\{
task5_terraform_state_backup_prev.png|codespace|cat[[:space:]]+terraform[.]tfstate[.]backup;;"resources";;(development_vpc|dev_subnet_1|aws_vpc|aws_subnet)
task5_terraform_apply_recreated.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;(aws_vpc|aws_subnet);;added
task5_terraform_state_file_populated.png|codespace|cat[[:space:]]+terraform[.]tfstate;;"resources";;(development_vpc|dev_subnet_1);;(aws_vpc|aws_subnet)
task5_terraform_state_backup_empty.png|codespace|cat[[:space:]]+terraform[.]tfstate[.]backup;;"resources"[[:space:]]*:[[:space:]]*\[
task5_terraform_state_list.png|codespace|terraform[[:space:]]+state[[:space:]]+list;;aws_vpc[.]development_vpc;;aws_subnet[.]dev_subnet_1
task5_terraform_state_show_resource.png|codespace|terraform[[:space:]]+state[[:space:]]+show;;(aws_vpc[.]development_vpc|aws_subnet[.]dev_subnet_1);;(id[[:space:]]*=|arn[[:space:]]*=|cidr_block[[:space:]]*=)
task6_terraform_outputs_basic.png|codespace|(dev-vpc-id|dev_vpc_id);;vpc-[0-9a-z]+;;(dev-subnet-id|dev_subnet_id);;subnet-[0-9a-z]+;;(dev-vpc-arn|dev_vpc_arn);;arn:aws:ec2;;(dev-subnet-arn|dev_subnet_arn)
task6_expanded_outputs.png|codespace|(dev-vpc-cidr_block|dev_vpc_cidr_block);;10[.]0[.]0[.]0/16;;(dev-vpc-region|dev_vpc_region);;me-central-1;;(dev-vpc-tags_name|development);;(dev-vpc-tags_all|tags_all);;(dev-subnet-cidr_block|10[.]0[.]10[.]0/24);;(dev-subnet-region|me-central-1a);;(dev-subnet-tags_name|subnet-1-dev)
cleanup_destroy_resources.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
cleanup_state_files.png|codespace|cat[[:space:]]+terraform[.]tfstate;;cat[[:space:]]+terraform[.]tfstate[.]backup;;"resources"
EOF

required=${#criteria[@]}

# This Vim confirmation screenshot is explicitly optional in the Lab10
# instructions and therefore does not reduce the student's score when absent.
optional_files=(
  task2_vim_save_main_tf.png
)

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab10-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab10-duplicate-images-${duplicate_key}.tsv"

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

summary="Passed $passed/$required Lab 10 required screenshot checks. Optional screenshots present: $optional_present/${#optional_files[@]} (not scored). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
