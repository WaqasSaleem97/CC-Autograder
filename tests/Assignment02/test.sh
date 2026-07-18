#!/usr/bin/env bash
set -u

# Grade Assignment 02 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Assignment02/test.sh \
#     work/submissions/Student/CC/Assignments/Assignment02 \
#     100
#
# Manual example:
#   bash tests/Assignment02/test.sh \
#     /path/to/CC/Assignments/Assignment02 \
#     100 \
#     waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut sort nproc; do
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
  json_error "Required directory is missing: Assignments/Assignment02/screenshots"
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
#   none     - no terminal-context requirement
#   terminal - username, Codespaces path, or user@host prompt must appear
#   ec2      - an ec2-user@host SSH prompt must appear
#
# The 55 required screenshots determine the base score. The six bonus
# screenshots are validated and reported separately; missing bonus work never
# reduces the base score.
readarray -t required_criteria <<'EOF'
assignment_part1_project_structure.png|terminal|(tree|assignment2);;main[.]tf;;variables[.]tf;;modules;;networking;;security;;webserver;;scripts
assignment_part1_gitignore.png|none|(gitignore|[.]terraform);;tfstate;;tfvars;;(pem|id_ed25519|private)
assignment_part1_variables_tf.png|none|variable;;vpc_cidr_block;;subnet_cidr_block;;availability_zone;;env_prefix;;instance_type;;public_key;;private_key;;backend_servers
assignment_part1_terraform_tfvars.png|none|vpc_cidr_block;;subnet_cidr_block;;availability_zone;;env_prefix;;instance_type;;public_key;;private_key
assignment_part1_networking_module_main.png|none|aws_vpc;;aws_subnet;;map_public_ip_on_launch;;internet_gateway;;route_table;;0[.]0[.]0[.]0/0
assignment_part1_networking_module_outputs.png|none|output;;vpc_id;;subnet_id;;igw_id;;route_table_id
assignment_part1_security_module.png|none|(security_group|aws_vpc_security_group);;(22|ssh);;(80|http);;(443|https);;(nginx|proxy);;backend
assignment_part1_security_groups_console.png|none|security[[:space:]]+groups?;;(nginx|proxy);;backend;;(inbound|outbound);;(80|443)
assignment_part1_locals_tf.png|none|locals;;my_ip;;common_tags;;backend_servers;;web-1;;web-2;;web-3;;(icanhazip|data[[:space:]]+"http")
assignment_part2_webserver_module_variables.png|none|variable;;env_prefix;;instance_name;;instance_type;;availability_zone;;subnet_id;;security_group_id;;public_key;;script_path;;instance_suffix
assignment_part2_webserver_module_main.png|none|aws_key_pair;;aws_instance;;ami;;associate_public_ip_address;;user_data;;security_group
assignment_part2_webserver_module_outputs.png|none|output;;instance_id;;public_ip;;private_ip
assignment_part2_main_tf_modules.png|none|module[[:space:]]+"nginx_server";;module[[:space:]]+"backend_servers";;for_each;;nginx_sg_id;;backend_sg_id;;nginx-setup[.]sh;;apache-setup[.]sh
assignment_part3_apache_script.png|none|(yum|dnf).*httpd;;systemctl.*httpd;;169[.]254[.]169[.]254;;(imdsv2|metadata-token);;index[.]html
assignment_part3_backend_webpage.png|none|backend[[:space:]]+web[[:space:]]+server;;hostname;;private[[:space:]]+ip;;public[[:space:]]+ip;;(terraform|active[[:space:]]+and[[:space:]]+running)
assignment_part3_nginx_script.png|none|(yum|dnf).*nginx;;openssl;;selfsigned;;(upstream|backend_servers);;(proxy_cache|cache);;(strict-transport-security|x-frame-options|security[[:space:]]+headers)
assignment_part3_nginx_default_page.png|none|(welcome[[:space:]]+to[[:space:]]+nginx|nginx[[:space:]]+test[[:space:]]+page|nginx);;http(s)?://[0-9]{1,3}([.][0-9]{1,3}){3}
assignment_part4_ssh_keygen.png|terminal|ssh-keygen;;ed25519;;id_ed25519;;(fingerprint|randomart|public[[:space:]]+key)
assignment_part4_terraform_init.png|terminal|terraform[[:space:]]+init;;successfully[[:space:]]+initialized;;(provider|hashicorp/aws)
assignment_part4_terraform_validate.png|terminal|terraform[[:space:]]+validate;;configuration[[:space:]]+is[[:space:]]+valid
assignment_part4_terraform_plan.png|terminal|terraform[[:space:]]+plan;;plan:;;to[[:space:]]+add;;(aws_instance|module[.])
assignment_part4_terraform_apply.png|terminal|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;(nginx|web-1|backend);;(aws_instance|instance)
assignment_part4_terraform_output.png|terminal|terraform[[:space:]]+output;;nginx_public_ip;;backend_servers_info;;(vpc_id|subnet_id);;[0-9]{1,3}([.][0-9]{1,3}){3}
assignment_part4_outputs_json.png|none|(nginx_public_ip|nginx_instance_id);;backend_servers_info;;(web-1|web-2|web-3);;(vpc_id|subnet_id)
assignment_part4_aws_vpc.png|none|(vpc|virtual[[:space:]]+private[[:space:]]+cloud);;(available|assignment|prod);;10[.][0-9]+[.][0-9]+[.][0-9]+/16
assignment_part4_aws_subnet.png|none|subnet;;(available|public);;10[.][0-9]+[.][0-9]+[.][0-9]+/24;;(availability[[:space:]]+zone|me-central)
assignment_part4_aws_security_groups.png|none|security[[:space:]]+groups?;;(nginx|proxy);;backend;;(80|443);;(inbound|outbound)
assignment_part4_aws_instances.png|none|instances?;;running;;nginx;;web-1;;web-2;;web-3
assignment_part5_ssh_nginx.png|ec2|ssh[[:space:]]+ec2-user@;;(amazon[[:space:]]+linux|last[[:space:]]+login|ec2)
assignment_part5_nginx_conf_updated.png|none|upstream[[:space:]]+backend_servers;;server[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}:80;;backup
assignment_part5_nginx_test.png|ec2|nginx[[:space:]]+-t;;syntax[[:space:]]+is[[:space:]]+ok;;test[[:space:]]+is[[:space:]]+successful
assignment_part5_nginx_restart.png|ec2|systemctl[[:space:]]+(restart|status)[[:space:]]+nginx;;active[[:space:]]*[(]running[)]
assignment_part5_ssl_warning.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;(connection[[:space:]]+is[[:space:]]+not[[:space:]]+private|potential[[:space:]]+security[[:space:]]+risk|your[[:space:]]+connection[[:space:]]+is[[:space:]]+not[[:space:]]+secure|advanced)
assignment_part5_web1_response.png|none|backend[[:space:]]+web[[:space:]]+server;;web-1;;(hostname|instance[[:space:]]+id|private[[:space:]]+ip)
assignment_part5_web2_response.png|none|backend[[:space:]]+web[[:space:]]+server;;web-2;;(hostname|instance[[:space:]]+id|private[[:space:]]+ip)
assignment_part5_load_balancing_demo.png|none|(load[[:space:]]+balanc|multiple[[:space:]]+reload|request);;web-1;;web-2
assignment_part5_cache_miss.png|none|x-cache-status;;miss;;(headers|network|https)
assignment_part5_cache_hit.png|none|x-cache-status;;hit;;(headers|network|https)
assignment_part5_cache_directory.png|ec2|ls[[:space:]]+-la[[:space:]]+/var/cache/nginx;;(total|cache|nginx)
assignment_part5_access_log_cache.png|ec2|(access[.]log|/var/log/nginx/access);;cache:;;(hit|miss)
assignment_part5_web1_stopped.png|ec2|systemctl[[:space:]]+stop[[:space:]]+httpd;;(inactive|dead|stopped|failed);;(web-1|httpd)
assignment_part5_web2_stopped.png|ec2|systemctl[[:space:]]+stop[[:space:]]+httpd;;(inactive|dead|stopped|failed);;(web-2|httpd)
assignment_part5_backup_activated.png|none|backend[[:space:]]+web[[:space:]]+server;;web-3;;(backup|active[[:space:]]+and[[:space:]]+running|hostname)
assignment_part5_nginx_error_log.png|ec2|(error[.]log|/var/log/nginx/error);;(upstream|connect|failed|refused|timed[[:space:]]+out|unavailable)
assignment_part5_services_restored.png|ec2|systemctl[[:space:]]+(start|status)[[:space:]]+httpd;;active[[:space:]]*[(]running[)];;(web-1|web-2|httpd)
assignment_part5_ssl_certificate.png|terminal|(openssl[[:space:]]+(s_client|x509)|certificate);;(subject|issuer);;(not[[:space:]]+before|not[[:space:]]+after|validity|tls)
assignment_part5_security_headers.png|terminal|(strict-transport-security|x-frame-options);;x-content-type-options;;(http/|curl[[:space:]]+-i)
assignment_part5_http_redirect.png|terminal|curl[[:space:]]+-i;;http://[0-9]{1,3}([.][0-9]{1,3}){3};;301;;location:.*https://
assignment_part5_error_log_analysis.png|ec2|(tail|grep).*(error[.]log|/var/log/nginx/error);;(error|warn|upstream|notice|connect)
assignment_part5_access_log_analysis.png|ec2|(tail|grep).*(access[.]log|/var/log/nginx/access);;(get|head|post);;http/;;[[:space:]](200|301|304|404|502)[[:space:]]
assignment_part6_readme.png|none|assignment[[:space:]_-]*2;;(project[[:space:]]+overview|architecture);;prerequisites;;deployment;;nginx;;terraform;;troubleshooting
assignment_part6_terraform_destroy_prompt.png|terminal|terraform[[:space:]]+destroy;;plan:;;to[[:space:]]+destroy;;(enter[[:space:]]+a[[:space:]]+value|only[[:space:]]+'yes'|yes)
assignment_part6_terraform_destroy_complete.png|terminal|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
assignment_part6_aws_instances_destroyed.png|none|instances?;;(terminated|no[[:space:]]+instances|0[[:space:]]+running|no[[:space:]]+running[[:space:]]+instances)
assignment_part6_empty_state.png|terminal|(terraform[.]tfstate|describe-instances);;("resources"[[:space:]]*:[[:space:]]*\[|\[[[:space:]]*\]);;("outputs"[[:space:]]*:[[:space:]]*\{|reservations)
EOF

readarray -t bonus_criteria <<'EOF'
bonus1_custom_404.png|none|404;;(not[[:space:]]+found|page[[:space:]]+not[[:space:]]+found);;(custom|nginx|assignment)
bonus1_custom_502.png|none|502;;bad[[:space:]]+gateway;;(custom|nginx|backend)
bonus2_rate_limit_config.png|none|limit_req_zone;;limit_req;;(rate=10r/s|burst=20|mylimit)
bonus2_rate_limit_test.png|terminal|429;;too[[:space:]]+many[[:space:]]+requests;;(curl|http/)
bonus3_health_check_script.png|none|(while|sleep[[:space:]]+30);;(curl|systemctl);;httpd;;(health|backend|log)
bonus3_health_log.png|ec2|(healthy|down|failed|restarted);;(web-1|web-2|web-3|backend);;20[0-9]{2}[-/]
EOF

required=${#required_criteria[@]}
all_criteria=("${required_criteria[@]}" "${bonus_criteria[@]}")

# Index screenshots recursively so students may use screenshots/part1,
# screenshots/part2, ..., screenshots/bonus as described in the assignment.
# Normalize the assignment's accidental `. png` names to `.png`.
work_dir="$(mktemp -d "/tmp/assignment02-${normalized_username}.XXXXXX")"
ocr_dir="$work_dir/ocr"
screenshot_index="$work_dir/screenshots.tsv"
resolved_index="$work_dir/resolved.tsv"
mkdir -p "$ocr_dir"

cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

python3 - "$screenshots_dir" "$screenshot_index" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
output = pathlib.Path(sys.argv[2])
rows = []

def normalize(name):
    name = name.strip().lower()
    return re.sub(r"\.\s+(png|jpg|jpeg)$", r".\1", name)

for path in root.rglob("*"):
    if not path.is_file():
        continue
    canonical = normalize(path.name)
    if pathlib.Path(canonical).suffix not in {".png", ".jpg", ".jpeg"}:
        continue
    rows.append((canonical, len(path.relative_to(root).parts), str(path.resolve())))

seen = set()
with output.open("w", encoding="utf-8") as handle:
    for canonical, _depth, path in sorted(rows):
        if canonical in seen:
            continue
        seen.add(canonical)
        handle.write(f"{canonical}\t{path}\n")
PY

resolve_screenshot_path() {
  local key
  key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  awk -F '\t' -v key="$key" '$1 == key {print $2; exit}' "$screenshot_index"
}

: > "$resolved_index"
for rule in "${all_criteria[@]}"; do
  filename="${rule%%|*}"
  image="$(resolve_screenshot_path "$filename")"
  if [[ -n "$image" ]]; then
    printf '%s\t%s\n' "$filename" "$image" >> "$resolved_index"
  fi
done

# OCR screenshots concurrently using all available logical CPUs, capped at 8.
# OCR_JOBS may be used to request fewer workers.
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

export ASSIGNMENT02_OCR_DIR="$ocr_dir"
while IFS=$'\t' read -r filename image; do
  printf '%s\0%s\0' "$filename" "$image"
done < "$resolved_index" |
  xargs -0 -r -P "$ocr_jobs" -n 2 \
    bash -c '
      filename="$1"
      source_image="$2"
      output_base="$ASSIGNMENT02_OCR_DIR/${filename%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _
unset ASSIGNMENT02_OCR_DIR

# Build an exact-duplicate index for the same normalized screenshot filename
# across all selected students. Both matching students receive zero for that
# screenshot. Files from different tasks are never compared.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/assignment02-duplicate-images-${duplicate_key}.tsv"

  if [[ ! -f "$duplicate_index" ]]; then
    python3 - "$submissions_root" "$relative_screenshots" "$duplicate_index" <<'PY'
import hashlib
import itertools
import pathlib
import re
import sys
from collections import defaultdict

root = pathlib.Path(sys.argv[1]).resolve()
relative = pathlib.PurePosixPath(sys.argv[2])
output = pathlib.Path(sys.argv[3])
groups = defaultdict(list)

def normalize(name):
    name = name.strip().lower()
    return re.sub(r"\.\s+(png|jpg|jpeg)$", r".\1", name)

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.rglob("*"):
        canonical = normalize(image.name)
        if image.is_file() and pathlib.Path(canonical).suffix in {".png", ".jpg", ".jpeg"}:
            groups[canonical].append(image.resolve())

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

record_failure() {
  feedback+=("$filename: $1 (0)")
}

passed=0
bonus_passed=0
bonus_submitted=0
feedback=()

for rule in "${all_criteria[@]}"; do
  filename="${rule%%|*}"
  remainder="${rule#*|}"
  identity_flag="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  image="$(resolve_screenshot_path "$filename")"
  is_bonus=false
  [[ "$filename" == bonus* ]] && is_bonus=true

  if [[ -z "$image" || ! -f "$image" ]]; then
    if [[ "$is_bonus" == false ]]; then
      record_failure "missing"
    fi
    continue
  fi

  if [[ "$is_bonus" == true ]]; then
    bonus_submitted=$((bonus_submitted + 1))
  fi

  # Confirm Pillow can decode the image. No minimum dimensions or file size are
  # required.
  if ! python3 - "$image" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys

with Image.open(sys.argv[1]) as image:
    image.verify()
PY
  then
    record_failure "invalid or corrupt image"
    continue
  fi

  canonical_image="$(realpath "$image")"
  if [[ -n "$duplicate_index" && -s "$duplicate_index" ]]; then
    duplicate_reason="$(awk -F '\t' -v path="$canonical_image" '$1 == path {print $2; exit}' "$duplicate_index")"
    if [[ -n "$duplicate_reason" ]]; then
      record_failure "$duplicate_reason"
      continue
    fi
  fi

  ocr_file="$ocr_dir/${filename%.*}.txt"
  ocr_text=""
  if [[ -f "$ocr_file" ]]; then
    ocr_text="$(tr '[:upper:]' '[:lower:]' < "$ocr_file")"
  fi

  if [[ -z "${ocr_text//[[:space:]]/}" ]]; then
    record_failure "unreadable OCR"
    continue
  fi

  # Reject exposed private keys, cloud credentials, GitHub tokens, passwords,
  # and bearer tokens. Whitespace-normalized OCR catches URLs that Tesseract
  # splits around punctuation.
  compact_ocr_text="$(printf '%s' "$ocr_text" | tr -d '[:space:]')"
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,}|https?://[^[:space:]@/:]+:[^[:space:]@/<>]{6,}@|authorization:[[:space:]]*(token|bearer)[[:space:]]+[0-9a-z._-]{12,}|(password|secret_access_key|access[[:space:]_-]*token)[[:space:]:=]+[0-9a-z/+=._-]{12,})' <<<"$ocr_text" || \
     grep -Eqi -- '(https?://[^@/:]+:[^@/<>]{6,}@|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|authorization:(token|bearer)[0-9a-z._-]{12,}|(password|secret_access_key|accesstoken)[:=][0-9a-z/+=._-]{12,})' <<<"$compact_ocr_text"; then
    record_failure "exposed credential, token, password, or private-key material is visible"
    continue
  fi

  identity_pattern=""
  identity_message=""
  case "$identity_flag" in
    terminal)
      identity_pattern="((^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)|/workspaces/|codespaces?|[[:alnum:]_.-]+[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+)"
      identity_message="terminal workspace or user@host context was not clearly detected"
      ;;
    ec2)
      identity_pattern="ec2-user[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+"
      identity_message="ec2-user@host SSH prompt was not clearly detected"
      ;;
  esac

  if [[ -n "$identity_pattern" ]] && ! grep -Eqi "$identity_pattern" <<<"$ocr_text"; then
    record_failure "$identity_message"
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
    record_failure "required task evidence was not detected"
    continue
  fi

  if [[ "$is_bonus" == true ]]; then
    bonus_passed=$((bonus_passed + 1))
    feedback+=("$filename: optional bonus passed")
  else
    passed=$((passed + 1))
    feedback+=("$filename: passed")
  fi
done

# Every required screenshot has equal weight. Bonus evidence is reported but is
# not added automatically because the portal's obtained score must not exceed
# TOTAL_MARKS.
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

summary="Passed $passed/$required Assignment 02 required screenshot checks. Bonus evidence passed: $bonus_passed/${#bonus_criteria[@]} (submitted: $bonus_submitted; reported separately, not included in the base score). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
