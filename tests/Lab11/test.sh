#!/usr/bin/env bash
set -u

# Grade Lab 11 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab11/test.sh \
#     work/submissions/Student/CC/Labs/Lab11 \
#     10
#
# Manual example:
#   bash tests/Lab11/test.sh /path/to/CC/Labs/Lab11 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab11/screenshots"
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
#   none      - no terminal identity requirement (editor/browser/AWS Console)
#   codespace - GitHub username, /workspaces path, or Codespaces context required
#   ec2       - an ec2-user@<host> terminal prompt must appear
#
# Repeated Save lines in the lab that use the same filename are intentionally
# represented once. Each unique required screenshot therefore has equal weight.
readarray -t criteria <<'EOF'
taskA_codespace_create_and_list.png|none|gh[[:space:]]+repo[[:space:]]+create;;lab11;;gh[[:space:]]+codespace[[:space:]]+create;;gh[[:space:]]+codespace[[:space:]]+list
taskA_codespace_ssh_connected.png|codespace|gh[[:space:]]+codespace[[:space:]]+ssh;;(codespace|/workspaces/|github)
task1_touch_main_tf.png|codespace|touch[[:space:]]+main[.]tf;;(ls|main[.]tf)
task1_main_tf_provider.png|none|provider[[:space:]]+"aws";;shared_config_files;;[.]aws/config;;shared_credentials_files;;[.]aws/credentials
task1_terraform_init.png|codespace|terraform[[:space:]]+init;;terraform[[:space:]]+has[[:space:]]+been[[:space:]]+successfully[[:space:]]+initialized;;(hashicorp/aws|provider)
task1_variable_and_output_added.png|none|variable[[:space:]]+"subnet_cidr_block";;type[[:space:]]*=[[:space:]]*string;;output[[:space:]]+"subnet_cidr_block";;var[.]subnet_cidr_block
task1_apply_prompt_for_var.png|codespace|terraform[[:space:]]+apply;;var[.]subnet_cidr_block;;enter[[:space:]]+a[[:space:]]+value
task1_apply_with_default.png|codespace|terraform[[:space:]]+apply;;10[.]0[.]0[.]0/24;;subnet_cidr_block
task1_env_var_set_and_apply.png|codespace|export[[:space:]]+tf_var_subnet_cidr_block;;10[.]0[.]20[.]0/24;;terraform[[:space:]]+apply;;subnet_cidr_block
task1_terraform_tfvars_and_apply.png|codespace|terraform[.]tfvars;;subnet_cidr_block;;10[.]0[.]30[.]0/24;;terraform[[:space:]]+apply
task1_var_override_with_dash_var.png|codespace|terraform[[:space:]]+apply;;-var;;subnet_cidr_block;;10[.]0[.]40[.]0/24
task1_printenv_tf_var_and_unset.png|codespace|printenv[[:space:]]+tf_var_subnet_cidr_block;;unset[[:space:]]+tf_var_subnet_cidr_block
task2_subnet_variable_with_validation.png|none|variable[[:space:]]+"subnet_cidr_block";;validation;;can[[:space:]]*[(].*regex;;10[.]0[.]0[.]0/16;;error_message
task2_subnet_validation_error.png|codespace|terraform[[:space:]]+apply;;10[.]0[.]0([^/]|$);;(invalid[[:space:]]+value|validation|error);;10[.]0[.]0[.]0/16
task2_api_token_variable_added.png|none|variable[[:space:]]+"api_session_token";;sensitive[[:space:]]*=[[:space:]]*true;;output[[:space:]]+"api_session_token_output";;var[.]api_session_token
task2_api_token_apply_sensitive.png|codespace|terraform[[:space:]]+apply;;api_session_token;;(sensitive[[:space:]]+value|sensitive|hidden)
task2_check_terraform_state_api_token.png|codespace|terraform[.]tfstate;;api_session_token_output;;"sensitive"[[:space:]]*:[[:space:]]*true
task2_api_token_ephemeral_error.png|codespace|ephemeral[[:space:]]*=[[:space:]]*true;;terraform[[:space:]]+apply;;(error|ephemeral);;(output|state)
task2_api_token_default_apply.png|codespace|api_session_token;;terraform[[:space:]]+apply;;(sensitive[[:space:]]+value|sensitive|hidden);;(apply[[:space:]]+complete|changes[[:space:]]+to[[:space:]]+outputs)
task3_variables_added.png|none|variable[[:space:]]+"environment";;variable[[:space:]]+"project_name";;variable[[:space:]]+"primary_subnet_id";;variable[[:space:]]+"subnet_count";;variable[[:space:]]+"monitoring"
task3_terraform_tfvars_populated.png|codespace|aws[[:space:]]+ec2[[:space:]]+describe-subnets;;me-central-1a;;subnet-[0-9a-z]+;;environment;;project_name;;primary_subnet_id;;subnet_count;;monitoring
task3_locals_tf_created.png|none|locals[[:space:]]*\{;;resource_name;;primary_public_subnet;;subnet_count;;is_production;;monitoring_enabled
task3_outputs_apply.png|codespace|terraform[[:space:]]+apply;;resource_name;;primary_public_subnet;;subnet_count;;is_production;;monitoring_enabled
task4_tags_variable_added.png|none|variable[[:space:]]+"tags";;type[[:space:]]*=[[:space:]]*map[(]string[)];;output[[:space:]]+"tags";;var[.]tags
task4_tags_output.png|codespace|terraform[[:space:]]+apply;;environment;;dev;;project;;sample-app;;owner;;platform-team
task4_server_config_output.png|codespace|server_config;;web-server;;t3[.]micro;;monitoring;;backup_enabled;;terraform[[:space:]]+apply
task5_collections_defined.png|none|variable[[:space:]]+"server_names";;list[(]string[)];;variable[[:space:]]+"server_metadata";;tuple;;variable[[:space:]]+"unique_zones";;set[(]string[)];;output[[:space:]]+"collection_comparison"
task5_compare_collections.png|codespace|terraform[[:space:]]+apply;;server_names;;server_metadata;;unique_zones;;web-1;;web-2;;me-central-1a
task5_locals_mutations.png|none|locals[[:space:]]*\{;;setunion;;mutated_list;;mutated_tuple;;mutated_set;;web-3
task5_mutation_comparison.png|codespace|terraform[[:space:]]+apply;;original_tuple;;mutated_tuple;;server_metadata;;web-2
task6_optional_tag_variable.png|none|variable[[:space:]]+"optional_tag";;type[[:space:]]*=[[:space:]]*string;;default[[:space:]]*=[[:space:]]*null
task6_locals_merge.png|none|merge[(];;base_tags;;optional_tag;;custom;;var[.]optional_tag[[:space:]]*!=[[:space:]]*null
task6_optional_tag_no_value.png|codespace|terraform[[:space:]]+apply;;final_tags;;name;;web-server
task6_optional_tag_with_value.png|codespace|optional_tag;;dev;;terraform[[:space:]]+apply;;final_tags;;custom
task6_dynamic_value_string.png|codespace|dynamic_value;;hello;;terraform[[:space:]]+apply
task6_dynamic_value_number.png|codespace|dynamic_value;;42;;terraform[[:space:]]+apply
task6_dynamic_value_list.png|codespace|dynamic_value;;"a";;"b";;"c";;terraform[[:space:]]+apply
task6_dynamic_value_map.png|codespace|dynamic_value;;server;;cpu;;4;;terraform[[:space:]]+apply
task6_dynamic_value_null.png|codespace|dynamic_value;;null;;terraform[[:space:]]+apply
task7_gitignore_created.png|none|[.]terraform/[*];;[*][.]tfstate;;[*][.]tfstate[.][*];;[*][.]tfvars;;[*][.]pem
task8_clean_files.png|none|(terraform[.]tfvars|locals[.]tf|main[.]tf);;provider[[:space:]]+"aws";;shared_config_files;;shared_credentials_files
task8_variables_recreated.png|none|variable[[:space:]]+"vpc_cidr_block";;variable[[:space:]]+"subnet_cidr_block";;variable[[:space:]]+"availability_zone";;variable[[:space:]]+"environment"
task8_vpc_resources_added.png|none|resource[[:space:]]+"aws_vpc"[[:space:]]+"myapp_vpc";;var[.]vpc_cidr_block;;enable_dns_hostnames;;myapp_vpc
task8_subnet_resources_added.png|none|resource[[:space:]]+"aws_subnet"[[:space:]]+"myapp_subnet_1";;aws_vpc[.]myapp_vpc[.]id;;var[.]subnet_cidr_block;;var[.]availability_zone
task8_terraform_tfvars_vpc_values.png|none|vpc_cidr_block;;10[.]0[.]0[.]0/16;;subnet_cidr_block;;10[.]0[.]10[.]0/24;;availability_zone;;me-central-1a;;environment;;dev
task8_vpc_subnet_apply.png|none|(terraform[[:space:]]+apply|aws[[:space:]]+console|virtual[[:space:]]+private[[:space:]]+cloud);;(aws_vpc[.]myapp_vpc|vpc-[0-9a-z]+);;(aws_subnet[.]myapp_subnet_1|subnet-[0-9a-z]+);;(apply[[:space:]]+complete|available|created)
task8_igw_route_table_before_apply.png|none|(aws_internet_gateway|internet[[:space:]]+gateway);;(aws_route_table|route[[:space:]]+table);;(myapp_igw|igw-[0-9a-z]+);;(myapp_route_table|rtb-[0-9a-z]+|0[.]0[.]0[.]0/0)
task8_igw_route_table_after_apply.png|none|(terraform[[:space:]]+apply|internet[[:space:]]+gateway);;(aws_internet_gateway[.]myapp_igw|igw-[0-9a-z]+);;(aws_route_table[.]myapp_route_table|rtb-[0-9a-z]+)
task8_association_apply.png|none|aws_route_table_association;;myapp_association;;myapp_subnet_1;;myapp_route_table;;(terraform[[:space:]]+apply|apply[[:space:]]+complete)
task8_default_route_table.png|none|resource[[:space:]]+"aws_default_route_table"[[:space:]]+"default_route_table";;default_route_table_id;;0[.]0[.]0[.]0/0;;myapp_default_route_table
task8_default_route_table_apply.png|none|terraform[[:space:]]+apply;;aws_default_route_table[.]default_route_table;;(apply[[:space:]]+complete|changed|updated)
task9_my_ip_variable_added.png|none|variable[[:space:]]+"my_ip";;variable[[:space:]]+"instance_type";;type[[:space:]]*=[[:space:]]*string
task9_public_ip_curl.png|codespace|curl[[:space:]]+(https?://)?icanhazip[.]com;;my_ip;;/32;;terraform[.]tfvars
task9_security_group_apply.png|none|(aws_default_security_group|security[[:space:]]+group|sg-[0-9a-z]+);;(myapp_sg|dev-sg|sg-[0-9a-z]+);;(terraform[[:space:]]+apply|apply[[:space:]]+complete|aws[[:space:]]+console|inbound[[:space:]]+rules)
task9_keypair_created_and_saved.png|none|(aws[[:space:]]+ec2[[:space:]]+create-key-pair|[*][.]pem);;(myed25519key|[.]pem);;(chmod[[:space:]]+600|gitignore|[*][.]pem)
task9_instance_type_set.png|none|variable[[:space:]]+"instance_type";;t3[.]micro;;resource[[:space:]]+"aws_instance"[[:space:]]+"myapp_server";;ami-[0-9a-z]+;;key_name;;myed25519key
task9_ec2_apply_and_public_ip.png|none|terraform[[:space:]]+apply;;aws_instance[.]myapp_server;;(apply[[:space:]]+complete|creation[[:space:]]+complete);;(public_ip|[0-9]{1,3}([.][0-9]{1,3}){3})
task9_ssh_into_ec2.png|ec2|ssh[[:space:]]+-i;;myed25519key[.]pem;;ec2-user@;;(amazon[[:space:]]+linux|ec2-user)
task9_ssh_keypair_and_ssh.png|none|(ssh-keygen|aws_key_pair|ssh[[:space:]]+ec2-user@);;(id_ed25519|serverkey|ec2-user@);;(public_key|key_name|successful|amazon[[:space:]]+linux|ec2-user@)
task9_nginx_local_curl.png|none|(curl[[:space:]]+localhost|entry-script[.]sh|user_data);;nginx;;(systemctl|welcome[[:space:]]+to[[:space:]]+nginx|curl[[:space:]]+localhost)
task9_nginx_browser_page.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
cleanup_destroy.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
cleanup_state_files.png|codespace|terraform[.]tfstate;;terraform[.]tfstate[.]backup;;(resources|outputs|version)
cleanup_verify_no_secrets.png|codespace|git[[:space:]]+status;;[.]gitignore;;([*][.]pem|[.]pem);;([*][.]tfstate|[.]tfstate);;([*][.]tfvars|[.]tfvars)
EOF

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab11-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab11-duplicate-images-${duplicate_key}.tsv"

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

  # Verify that the file is a decodable image. There is intentionally no
  # minimum-width, minimum-height, or file-size grading rule.
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
  # personal access tokens. Generic field labels are allowed when values are
  # hidden or visibly redacted.
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

# Every unique required screenshot has equal weight. Scale the result to the
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

summary="Passed $passed/$required Lab 11 required screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
