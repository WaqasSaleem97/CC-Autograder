#!/usr/bin/env bash
set -u

# Grade Lab 13 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab13/test.sh \
#     work/submissions/Student/CC/Labs/Lab13 \
#     10
#
# Manual example:
#   bash tests/Lab13/test.sh /path/to/CC/Labs/Lab13 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab13/screenshots"
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

# Accept corrected filenames and the accidental "name. png" forms printed in
# different Save/Required lists in the supplied Lab 13 instructions.
resolve_screenshot_name() {
  local canonical="$1"
  local candidate
  local -a candidates=("$canonical")

  case "$canonical" in
    task1_main_tf.png)
      candidates+=("task1_main_tf. png")
      ;;
    task5_tfstate_secret.png)
      candidates+=("task5_tfstate_secret. png")
      ;;
    task5_aws_console_access_keys.png)
      candidates+=("task5_aws_console_access_keys. png")
      ;;
    task6_main_tf_backend.png)
      candidates+=("task6_main_tf_backend. png")
      ;;
    task6_s3_tfstate_destroyed.png)
      candidates+=("task6_s3_tfstate_destroyed. png")
      ;;
    task7_tfstate_secrets.png)
      candidates+=("task7_tfstate_secrets. png")
      ;;
    task7_aws_console_all_users.png)
      candidates+=("task7_aws_console_all_users. png")
      ;;
    task7_aws_console_group_members.png)
      candidates+=("task7_aws_console_group_members. png")
      ;;
    cleanup_s3_bucket_deleted.png)
      candidates+=("cleanup_s3_bucket_deleted. png")
      ;;
  esac

  for candidate in "${candidates[@]}"; do
    if [[ -f "$screenshots_dir/$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf '%s' "$canonical"
}

# Format:
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none      - no terminal identity requirement (editor/AWS Console evidence)
#   codespace - GitHub username, /workspaces path, or Codespaces context required
readarray -t criteria <<'EOF'
task0_codespace_create_and_list.png|none|gh[[:space:]]+repo[[:space:]]+create;;lab13;;gh[[:space:]]+codespace[[:space:]]+create;;gh[[:space:]]+codespace[[:space:]]+list
task0_codespace_ssh_connected.png|codespace|gh[[:space:]]+codespace[[:space:]]+ssh;;(codespace|/workspaces/|github)
task1_project_directory.png|codespace|mkdir[[:space:]]+-p;;lab13;;cd[[:space:]]+.*lab13
task1_file_created.png|codespace|touch[[:space:]]+main[.]tf;;(ls|main[.]tf)
task1_main_tf.png|none|provider[[:space:]]+"aws";;aws_iam_group;;developers;;path[[:space:]]*=[[:space:]]*"/groups/";;output[[:space:]]+"group_details";;group_arn;;unique_id
task1_terraform_init.png|codespace|terraform[[:space:]]+init;;successfully[[:space:]]+initialized;;(hashicorp/aws|provider)
task1_terraform_apply.png|codespace|terraform[[:space:]]+apply;;aws_iam_group[.]developers;;creation[[:space:]]+complete;;apply[[:space:]]+complete
task1_terraform_output.png|codespace|terraform[[:space:]]+output;;group_details;;developers;;group_arn;;unique_id;;arn:aws:iam
task1_aws_console_group.png|none|(identity[[:space:]]+and[[:space:]]+access[[:space:]]+management|iam);;(user[[:space:]]+groups|groups);;developers
task2_main_tf_user.png|none|aws_iam_user;;loadbalancer;;force_destroy;;aws_iam_user_group_membership;;developers;;output[[:space:]]+"user_details"
task2_terraform_apply.png|codespace|terraform[[:space:]]+apply;;aws_iam_user[.]lb;;loadbalancer;;(aws_iam_user_group_membership|lb_membership);;apply[[:space:]]+complete
task2_terraform_output.png|codespace|terraform[[:space:]]+output;;group_details;;user_details;;developers;;loadbalancer;;arn:aws:iam
task2_aws_console_user.png|none|(identity[[:space:]]+and[[:space:]]+access[[:space:]]+management|iam);;users;;loadbalancer
task2_aws_console_user_groups.png|none|loadbalancer;;(groups|group[[:space:]]+memberships);;developers
task3_main_tf_policies.png|none|aws_iam_group_policy_attachment;;developers;;amazonec2fullaccess;;iamuserchangepassword;;policy_arn
task3_terraform_apply.png|codespace|terraform[[:space:]]+apply;;aws_iam_group_policy_attachment;;(developer_ec2_fullaccess|amazonec2fullaccess);;(change_password|iamuserchangepassword);;apply[[:space:]]+complete
task3_aws_console_policies.png|none|developers;;permissions;;amazonec2fullaccess;;iamuserchangepassword
task4_variables_tf.png|none|variable[[:space:]]+"iam_password";;temporary[[:space:]]+password;;type[[:space:]]*=[[:space:]]*string;;sensitive[[:space:]]*=[[:space:]]*true
task4_create_login_script.png|none|#!/usr/bin/env[[:space:]]+bash;;get-login-profile;;create-login-profile;;--user-name;;--password-reset-required
task4_chmod_script.png|codespace|chmod[[:space:]]+[+]x[[:space:]]+create-login-profile[.]sh;;(ls|create-login-profile[.]sh)
task4_main_tf_login_profile.png|none|null_resource;;create_login_profile;;password_hash;;sha256[(]var[.]iam_password[)];;provisioner[[:space:]]+"local-exec";;create-login-profile[.]sh
task4_terraform_apply.png|codespace|terraform[[:space:]]+apply;;(null_resource[.]create_login_profile|creating[[:space:]]+login[[:space:]]+profile);;loadbalancer;;apply[[:space:]]+complete
task4_aws_cli_verify.png|codespace|aws[[:space:]]+iam[[:space:]]+get-login-profile;;loadbalancer;;(createdate|passwordresetrequired|loginprofile)
task4_aws_console_login.png|none|(amazon[[:space:]]+web[[:space:]]+services|aws);;(iam[[:space:]]+user|account[[:space:]]+id);;loadbalancer;;sign[[:space:]]+in
task4_aws_console_password_reset.png|none|(password[[:space:]]+reset|required[[:space:]]+password[[:space:]]+change|change[[:space:]]+password);;(current[[:space:]]+password|new[[:space:]]+password|confirm)
task5_main_tf_access_keys.png|none|aws_iam_access_key;;lb_access_key;;output[[:space:]]+"access_key_id";;output[[:space:]]+"access_key_secret";;sensitive[[:space:]]*=[[:space:]]*true
task5_terraform_apply.png|codespace|terraform[[:space:]]+apply;;aws_iam_access_key[.]lb_access_key;;creation[[:space:]]+complete;;apply[[:space:]]+complete
task5_terraform_output.png|codespace|terraform[[:space:]]+output;;access_key_id;;access_key_secret;;(sensitive[[:space:]]+value|sensitive|redacted|hidden)
task5_tfstate_secret.png|codespace|terraform[.]tfstate;;access_key_secret;;"sensitive"[[:space:]]*:[[:space:]]*true;;(redacted|hidden|masked|"value")
task5_aws_console_access_keys.png|none|loadbalancer;;security[[:space:]]+credentials;;access[[:space:]]+keys;;(active|created|redacted|masked)
task6_s3_bucket_create.png|none|(amazon[[:space:]]+s3|s3);;create[[:space:]]+bucket;;(bucket[[:space:]]+name|general[[:space:]]+purpose);;(aws[[:space:]]+region|region)
task6_s3_bucket_versioning.png|none|(bucket[[:space:]]+versioning|versioning);;(enabled|enable);;(amazon[[:space:]]+s3|s3|bucket)
task6_main_tf_backend.png|none|terraform[[:space:]]*\{;;backend[[:space:]]+"s3";;bucket;;myapp/terraform[.]tfstate;;me-central-1;;encrypt[[:space:]]*=[[:space:]]*true;;use_lockfile[[:space:]]*=[[:space:]]*true
task6_terraform_init_migrate.png|codespace|terraform[[:space:]]+init[[:space:]]+-migrate-state;;(migrate|copy[[:space:]]+existing[[:space:]]+state|successfully[[:space:]]+configured[[:space:]]+the[[:space:]]+backend);;s3
task6_terraform_apply.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;(aws_iam|resources);;(added|changed|0[[:space:]]+added)
task6_s3_tfstate_file.png|none|myapp/;;terraform[.]tfstate;;(s3|objects|bucket)
task6_local_state_backup.png|codespace|ls[[:space:]]+-la[[:space:]]+terraform[.]tfstate[*];;(terraform[.]tfstate[.]backup|terraform[.]tfstate)
task6_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
task6_s3_tfstate_destroyed.png|none|terraform[.]tfstate;;(version|last[[:space:]]+modified|state|objects);;(s3|bucket|myapp/)
task7_locals_tf.png|none|locals[[:space:]]*\{;;users;;csvdecode;;file[(]"users[.]csv"[)]
task7_users_csv.png|none|user_name;;michael;;dwight;;jim;;pam;;ryan;;andy;;robert;;stanley;;kevin;;angela
task7_main_tf_multiple_users.png|none|for_each;;local[.]users;;aws_iam_user;;aws_iam_user_group_membership;;create_login_profiles;;aws_iam_access_key;;all_users_details;;all_access_key_secrets;;sensitive[[:space:]]*=[[:space:]]*true
task7_terraform_init.png|codespace|terraform[[:space:]]+init;;successfully[[:space:]]+initialized;;(s3|backend|provider)
task7_terraform_apply.png|codespace|terraform[[:space:]]+apply;;(aws_iam_user[.]users|create_login_profiles|users_access_keys);;apply[[:space:]]+complete;;added
task7_terraform_output.png|codespace|terraform[[:space:]]+output;;all_users_details;;all_access_key_secrets;;(sensitive[[:space:]]+value|sensitive|redacted|hidden);;(michael|dwight|jim|pam)
task7_tfstate_secrets.png|codespace|terraform[.]tfstate;;all_access_key_secrets;;"sensitive"[[:space:]]*:[[:space:]]*true;;(redacted|hidden|masked|"value")
task7_aws_console_all_users.png|none|(identity[[:space:]]+and[[:space:]]+access[[:space:]]+management|iam);;users;;michael;;dwight;;jim;;pam
task7_aws_console_group_members.png|none|developers;;users;;michael;;dwight;;jim;;pam
task7_aws_console_user_access_key.png|none|(michael|dwight|jim|pam);;security[[:space:]]+credentials;;access[[:space:]]+keys;;(active|created|redacted|masked)
task7_s3_tfstate_multiple_users.png|none|terraform[.]tfstate;;(version|last[[:space:]]+modified|objects);;(michael|users|state);;(s3|bucket|myapp/)
cleanup_destroy_complete.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
cleanup_aws_console_users_deleted.png|none|(identity[[:space:]]+and[[:space:]]+access[[:space:]]+management|iam);;users;;(no[[:space:]]+users|0[[:space:]]+users|no[[:space:]]+resources|create[[:space:]]+user)
cleanup_aws_console_group_deleted.png|none|(user[[:space:]]+groups|groups);;(no[[:space:]]+groups|0[[:space:]]+groups|no[[:space:]]+resources|create[[:space:]]+group)
cleanup_s3_empty_state.png|none|terraform[.]tfstate;;(empty|0[[:space:]]+resources|"resources"[[:space:]]*:[[:space:]]*\[|last[[:space:]]+modified);;(s3|bucket|myapp/)
cleanup_final_files.png|codespace|ls[[:space:]]+-la;;main[.]tf;;variables[.]tf;;locals[.]tf;;users[.]csv;;create-login-profile[.]sh;;[.]gitignore;;screenshots
EOF

required=${#criteria[@]}

# Deleting the backend bucket is explicitly optional and does not affect marks.
optional_files=(cleanup_s3_bucket_deleted.png)

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab13-ocr-${normalized_username}.XXXXXX")"
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

# Pass canonical and resolved filenames as NUL-delimited pairs so aliases that
# contain spaces remain safe and OCR output always uses the canonical basename.
printf '%s\n' "${criteria[@]}" |
  cut -d'|' -f1 |
  while IFS= read -r canonical; do
    resolved="$(resolve_screenshot_name "$canonical")"
    if [[ -f "$screenshots_dir/$resolved" ]]; then
      printf '%s\0%s\0' "$canonical" "$resolved"
    fi
  done |
  xargs -0 -r -P "$ocr_jobs" -n 2 \
    bash -c '
      screenshots_dir="$1"
      ocr_dir="$2"
      canonical="$3"
      resolved="$4"
      source_image="$screenshots_dir/$resolved"
      output_base="$ocr_dir/${canonical%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _ "$screenshots_dir" "$ocr_dir"

# Build one exact-duplicate index for screenshots representing the same task
# across all students selected in this workflow. Every matching copy gets zero.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab13-duplicate-images-${duplicate_key}.tsv"

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
aliases = {
    "task1_main_tf. png": "task1_main_tf.png",
    "task5_tfstate_secret. png": "task5_tfstate_secret.png",
    "task5_aws_console_access_keys. png": "task5_aws_console_access_keys.png",
    "task6_main_tf_backend. png": "task6_main_tf_backend.png",
    "task6_s3_tfstate_destroyed. png": "task6_s3_tfstate_destroyed.png",
    "task7_tfstate_secrets. png": "task7_tfstate_secrets.png",
    "task7_aws_console_all_users. png": "task7_aws_console_all_users.png",
    "task7_aws_console_group_members. png": "task7_aws_console_group_members.png",
    "cleanup_s3_bucket_deleted. png": "cleanup_s3_bucket_deleted.png",
}

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        lower_name = image.name.lower()
        is_supported_image = image.suffix.lower() in {".png", ".jpg", ".jpeg"}
        if image.is_file() and (is_supported_image or lower_name in aliases):
            task_name = aliases.get(lower_name, lower_name)
            groups[task_name].append(image.resolve())

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
  resolved_filename="$(resolve_screenshot_name "$filename")"
  image="$screenshots_dir/$resolved_filename"

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

  # Reject private keys, AWS credentials, GitHub tokens, exposed IAM passwords,
  # and 40-character values shaped like AWS secret access keys. State-related
  # screenshots must redact the value while preserving labels and metadata.
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,}|iam_password[[:space:]]*=[[:space:]]*[\"]?[0-9a-z!@#%&*._+-]{8,}|mysecurepass|1dontknow|(^|[^0-9a-z/+=])[0-9a-z/+=]{40}([^0-9a-z/+=]|$))' <<<"$ocr_text"; then
    feedback+=("$filename: exposed password, access key, token, or private-key material is visible (0)")
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
  resolved_optional="$(resolve_screenshot_name "$optional_file")"
  [[ -f "$screenshots_dir/$resolved_optional" ]] && optional_present=$((optional_present + 1))
done

# Every required screenshot has equal weight. Scale passed checks to the
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

summary="Passed $passed/$required Lab 13 required screenshot checks. Optional screenshots present: $optional_present/${#optional_files[@]} (not scored). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
