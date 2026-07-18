#!/usr/bin/env bash
set -u

# Grade Lab 12 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab12/test.sh \
#     work/submissions/Student/CC/Labs/Lab12 \
#     10
#
# Manual example:
#   bash tests/Lab12/test.sh /path/to/CC/Labs/Lab12 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab12/screenshots"
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

# The lab's Save lines contain spaces before the .png extension in two names.
# Accept both the corrected filenames and the names printed in the lab manual.
resolve_screenshot_name() {
  local canonical="$1"
  local candidate
  local -a candidates=("$canonical")

  case "$canonical" in
    task0_codespace_create_and_list.png)
      candidates+=("task0_codespace_create_and_list. png")
      ;;
    task1_terraform_tfvars.png)
      candidates+=("task1_terraform_tfvars. png")
      ;;
    task7_ssh_webserver.png)
      candidates+=("task7_ssh_webserver. png")
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
#   none      - no terminal identity requirement (editor/browser evidence)
#   codespace - GitHub username, /workspaces path, or Codespaces context required
#   ec2       - an ec2-user@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task0_codespace_create_and_list.png|none|gh[[:space:]]+repo[[:space:]]+create;;lab12;;gh[[:space:]]+codespace[[:space:]]+create;;gh[[:space:]]+codespace[[:space:]]+list
task0_codespace_ssh_connected.png|codespace|gh[[:space:]]+codespace[[:space:]]+ssh;;(codespace|/workspaces/|github)
task1_project_directory.png|codespace|mkdir[[:space:]]+-p;;lab12;;cd[[:space:]]+.*lab12
task1_files_created.png|codespace|ls[[:space:]]+-la;;main[.]tf;;variables[.]tf;;outputs[.]tf;;locals[.]tf;;terraform[.]tfvars;;entry-script[.]sh
task1_variables_tf.png|none|variable[[:space:]]+"vpc_cidr_block";;variable[[:space:]]+"subnet_cidr_block";;variable[[:space:]]+"availability_zone";;variable[[:space:]]+"env_prefix";;variable[[:space:]]+"instance_type";;variable[[:space:]]+"public_key";;variable[[:space:]]+"private_key"
task1_outputs_tf.png|none|output[[:space:]]+"aws_instance_public_ip";;aws_instance[.]myapp-server[.]public_ip
task1_locals_tf.png|none|locals[[:space:]]*\{;;my_ip;;chomp;;data[.]http[.]my_ip[.]response_body;;https://icanhazip[.]com
task1_terraform_tfvars.png|none|vpc_cidr_block;;10[.]0[.]0[.]0/16;;subnet_cidr_block;;10[.]0[.]10[.]0/24;;me-central;;t3[.]micro;;id_ed25519
task1_main_tf.png|none|provider[[:space:]]+"aws";;aws_vpc;;aws_subnet;;(aws_default_route_table|aws_internet_gateway);;(aws_default_security_group|aws_instance);;user_data
task1_entry_script.png|none|#!/bin/bash;;yum[[:space:]]+update;;yum[[:space:]]+install.*nginx;;systemctl[[:space:]]+start[[:space:]]+nginx;;systemctl[[:space:]]+enable[[:space:]]+nginx
task1_ssh_keygen.png|codespace|ssh-keygen;;ed25519;;id_ed25519
task1_terraform_init.png|codespace|terraform[[:space:]]+init;;terraform[[:space:]]+has[[:space:]]+been[[:space:]]+successfully[[:space:]]+initialized;;(hashicorp/aws|provider)
task1_terraform_apply.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;added;;(aws_instance|aws_vpc|aws_subnet)
task1_terraform_output.png|codespace|terraform[[:space:]]+output;;aws_instance_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task1_nginx_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task1_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;(destroy[[:space:]]+complete|plan:.*destroy|do[[:space:]]+you[[:space:]]+really[[:space:]]+want);;(destroyed|to[[:space:]]+destroy)
task2_main_tf_remote_exec.png|none|connection[[:space:]]*\{;;ec2-user;;private_key;;self[.]public_ip;;provisioner[[:space:]]+"remote-exec";;yum[[:space:]]+install.*nginx
task2_terraform_apply.png|codespace|terraform[[:space:]]+apply;;remote-exec;;(yum|nginx|systemctl);;apply[[:space:]]+complete
task2_terraform_output.png|codespace|terraform[[:space:]]+output;;aws_instance_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task2_nginx_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task3_main_tf_all_provisioners.png|none|provisioner[[:space:]]+"file";;entry-script-on-ec2[.]sh;;provisioner[[:space:]]+"remote-exec";;provisioner[[:space:]]+"local-exec";;instance.*public[[:space:]]+ip
task3_terraform_apply.png|codespace|terraform[[:space:]]+apply;;(file|remote-exec);;(local-exec|instance.*has[[:space:]]+been[[:space:]]+created);;apply[[:space:]]+complete
task3_terraform_output.png|codespace|terraform[[:space:]]+output;;aws_instance_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task3_nginx_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task3_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;(destroy[[:space:]]+complete|do[[:space:]]+you[[:space:]]+really[[:space:]]+want);;(destroyed|to[[:space:]]+destroy)
task3_main_tf_restored.png|none|aws_instance;;myapp-server;;user_data[[:space:]]*=[[:space:]]*file[(]"[.]?/entry-script[.]sh"[)]
task4_module_structure.png|codespace|modules/subnet;;main[.]tf;;variables[.]tf;;outputs[.]tf;;(tree|ls[[:space:]]+-r)
task4_subnet_variables.png|none|variable[[:space:]]+"vpc_id";;variable[[:space:]]+"subnet_cidr_block";;variable[[:space:]]+"availability_zone";;variable[[:space:]]+"env_prefix";;variable[[:space:]]+"default_route_table_id"
task4_subnet_main.png|none|aws_subnet;;myapp_subnet_1;;map_public_ip_on_launch;;aws_default_route_table;;aws_internet_gateway;;myapp_igw
task4_subnet_outputs.png|none|output[[:space:]]+"subnet";;aws_subnet[.]myapp_subnet_1
task4_main_tf_with_module.png|none|module[[:space:]]+"myapp-subnet";;source[[:space:]]*=[[:space:]]*"[.]?/modules/subnet";;default_route_table_id;;module[.]myapp-subnet[.]subnet[.]id
task4_terraform_init.png|codespace|terraform[[:space:]]+init;;(initializing[[:space:]]+modules|myapp-subnet|modules/subnet);;successfully[[:space:]]+initialized
task4_terraform_apply.png|codespace|terraform[[:space:]]+apply;;module[.]myapp-subnet;;apply[[:space:]]+complete;;added
task4_terraform_output.png|codespace|terraform[[:space:]]+output;;(aws_instance_public_ip|webserver_public_ip);;[0-9]{1,3}([.][0-9]{1,3}){3}
task4_nginx_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task5_webserver_module_structure.png|codespace|modules/webserver;;main[.]tf;;variables[.]tf;;outputs[.]tf;;(tree|ls[[:space:]]+-r)
task5_webserver_variables.png|none|variable[[:space:]]+"env_prefix";;variable[[:space:]]+"instance_type";;variable[[:space:]]+"availability_zone";;variable[[:space:]]+"public_key";;variable[[:space:]]+"my_ip";;variable[[:space:]]+"vpc_id";;variable[[:space:]]+"subnet_id";;variable[[:space:]]+"script_path";;variable[[:space:]]+"instance_suffix"
task5_webserver_main.png|none|aws_security_group;;web_sg;;from_port[[:space:]]*=[[:space:]]*443;;aws_key_pair;;aws_instance;;vpc_security_group_ids;;user_data
task5_webserver_outputs.png|none|output[[:space:]]+"aws_instance";;aws_instance[.]myapp-server
task5_main_tf_webserver_module.png|none|module[[:space:]]+"myapp-webserver";;source[[:space:]]*=[[:space:]]*"[.]?/modules/webserver";;my_ip[[:space:]]*=[[:space:]]*local[.]my_ip;;module[.]myapp-subnet[.]subnet[.]id;;entry-script[.]sh
task5_outputs_updated.png|none|output[[:space:]]+"webserver_public_ip";;module[.]myapp-webserver[.]aws_instance[.]public_ip
task5_terraform_init.png|codespace|terraform[[:space:]]+init;;(initializing[[:space:]]+modules|myapp-webserver|modules/webserver);;successfully[[:space:]]+initialized
task5_terraform_apply.png|codespace|terraform[[:space:]]+apply;;module[.]myapp-webserver;;apply[[:space:]]+complete;;added
task5_terraform_output.png|codespace|terraform[[:space:]]+output;;webserver_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task5_nginx_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task5_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;(destroy[[:space:]]+complete|do[[:space:]]+you[[:space:]]+really[[:space:]]+want);;(destroyed|to[[:space:]]+destroy)
task6_entry_script_https.png|none|openssl[[:space:]]+req;;selfsigned[.]key;;selfsigned[.]crt;;listen[[:space:]]+443[[:space:]]+ssl;;return[[:space:]]+301[[:space:]]+https
task6_terraform_apply.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;(aws_instance|module[.]myapp-webserver);;(added|changed)
task6_terraform_output.png|codespace|terraform[[:space:]]+output;;webserver_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task6_browser_security_warning.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;(potential[[:space:]]+security[[:space:]]+risk|your[[:space:]]+connection[[:space:]]+is[[:space:]]+not[[:space:]]+private|warning);;(advanced|accept[[:space:]]+the[[:space:]]+risk)
task6_nginx_https_browser.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task6_http_redirect.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx|https)
task7_apache_script.png|none|#!/bin/bash;;yum[[:space:]]+install[[:space:]]+httpd;;systemctl[[:space:]]+start[[:space:]]+httpd;;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;deployed[[:space:]]+via[[:space:]]+terraform
task7_main_tf_web1.png|none|module[[:space:]]+"myapp-web-1";;source[[:space:]]*=[[:space:]]*"[.]?/modules/webserver";;script_path[[:space:]]*=[[:space:]]*"[.]?/apache[.]sh";;instance_suffix[[:space:]]*=[[:space:]]*"1"
task7_outputs_web1.png|none|output[[:space:]]+"aws_web-1_public_ip";;module[.]myapp-web-1[.]aws_instance[.]public_ip
task7_terraform_apply.png|codespace|terraform[[:space:]]+apply;;(module[.]myapp-web-1|myapp-web-1);;apply[[:space:]]+complete;;added
task7_terraform_output.png|codespace|terraform[[:space:]]+output;;(aws_web-1_public_ip|webserver_public_ip);;[0-9]{1,3}([.][0-9]{1,3}){3}
task7_ssh_webserver.png|ec2|ssh[[:space:]]+ec2-user@;;ec2-user@
task7_nginx_conf_reverse_proxy.png|none|location[[:space:]]+/;;proxy_pass[[:space:]]+http://[0-9]{1,3}([.][0-9]{1,3}){3}:80;;backend_servers
task7_nginx_restart.png|ec2|sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+nginx
task7_error_log.png|ec2|cat[[:space:]]+/var/log/nginx/error[.]log
task7_access_log.png|ec2|cat[[:space:]]+/var/log/nginx/access[.]log;;(get[[:space:]]+/|http/1|200|304)
task7_mime_types.png|ec2|cat[[:space:]]+/etc/nginx/mime[.]types;;types[[:space:]]*\{;;text/html;;application/(json|javascript)
task7_ssl_cert.png|none|/etc/ssl/certs/selfsigned[.]crt;;begin[[:space:]]+certificate
task7_ssl_key.png|none|/etc/ssl/private/selfsigned[.]key;;(ls[[:space:]]+-l|permissions|[-]rw)
task7_reverse_proxy_browser.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;(hostname|private[[:space:]]+ip|public[[:space:]]+ip|deployed[[:space:]]+via[[:space:]]+terraform)
task8_main_tf_web2.png|none|module[[:space:]]+"myapp-web-2";;source[[:space:]]*=[[:space:]]*"[.]?/modules/webserver";;script_path[[:space:]]*=[[:space:]]*"[.]?/apache[.]sh";;instance_suffix[[:space:]]*=[[:space:]]*"2"
task8_outputs_web2.png|none|output[[:space:]]+"aws_web-2_public_ip";;module[.]myapp-web-2[.]aws_instance[.]public_ip
task8_terraform_apply.png|codespace|terraform[[:space:]]+apply;;(module[.]myapp-web-2|myapp-web-2);;apply[[:space:]]+complete;;added
task8_terraform_output.png|codespace|terraform[[:space:]]+output;;aws_web-1_public_ip;;aws_web-2_public_ip;;webserver_public_ip;;[0-9]{1,3}([.][0-9]{1,3}){3}
task8_nginx_conf_load_balancer.png|none|upstream[[:space:]]+backend_servers;;server[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}:80;;proxy_pass[[:space:]]+http://backend_servers
task8_nginx_restart.png|ec2|sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+nginx
task8_load_balancer_web1.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;(web-1|hostname|private[[:space:]]+ip|public[[:space:]]+ip)
task8_load_balancer_web2.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;(web-2|hostname|private[[:space:]]+ip|public[[:space:]]+ip)
task9_nginx_conf_ha_web1_primary.png|none|upstream[[:space:]]+backend_servers;;server[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}:80;;backup
task9_ha_web1_only.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;(web-1|hostname|private[[:space:]]+ip|public[[:space:]]+ip)
task9_nginx_conf_ha_web2_primary.png|none|upstream[[:space:]]+backend_servers;;server[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}:80[[:space:]]+backup;;server[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}:80
task9_ha_web2_only.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;welcome[[:space:]]+to[[:space:]]+my[[:space:]]+web[[:space:]]+server;;(web-2|hostname|private[[:space:]]+ip|public[[:space:]]+ip)
task10_nginx_conf_cache.png|none|proxy_cache_path;;/var/cache/nginx;;keys_zone=my_cache;;proxy_cache[[:space:]]+my_cache;;proxy_cache_valid[[:space:]]+200[[:space:]]+60m;;x-cache-status
task10_nginx_restart.png|ec2|sudo[[:space:]]+systemctl[[:space:]]+restart[[:space:]]+nginx
task10_cache_miss.png|none|x-cache-status;;miss
task10_cache_hit.png|none|x-cache-status;;hit
task10_cache_directory.png|ec2|ls[[:space:]]+-la[[:space:]]+/var/cache/nginx/?
cleanup_destroy_prompt.png|codespace|terraform[[:space:]]+destroy;;do[[:space:]]+you[[:space:]]+really[[:space:]]+want;;enter[[:space:]]+a[[:space:]]+value
cleanup_destroy_complete.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
cleanup_state_empty.png|codespace|cat[[:space:]]+terraform[.]tfstate;;"resources"[[:space:]]*:[[:space:]]*\[;;"outputs"[[:space:]]*:[[:space:]]*\{
cleanup_final_files.png|codespace|(tree|ls[[:space:]]+-la);;modules;;subnet;;webserver;;main[.]tf;;variables[.]tf;;outputs[.]tf;;locals[.]tf;;entry-script[.]sh;;apache[.]sh;;screenshots
EOF

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab12-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab12-duplicate-images-${duplicate_key}.tsv"

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
    "task0_codespace_create_and_list. png": "task0_codespace_create_and_list.png",
    "task1_terraform_tfvars. png": "task1_terraform_tfvars.png",
    "task7_ssh_webserver. png": "task7_ssh_webserver.png",
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

  # Reject exposure of private keys, AWS credentials, and GitHub tokens. The
  # task7_ssl_key screenshot must show safe file/path/permission evidence, not
  # the private key body requested by the current lab text.
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,})' <<<"$ocr_text"; then
    feedback+=("$filename: sensitive credential or private-key material is visible (0)")
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

summary="Passed $passed/$required Lab 12 required screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
