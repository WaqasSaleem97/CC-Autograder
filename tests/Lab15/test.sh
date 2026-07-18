#!/usr/bin/env bash
set -u

# Grade the Lab 15 Terraform + Ansible project using its 100-mark rubric.
# Lab 15 defines no required screenshot filenames, so this test performs static
# project analysis and does not deploy AWS resources.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab15/test.sh \
#     work/submissions/Student/CC/Labs/Lab15 \
#     100
#
# Manual example:
#   bash tests/Lab15/test.sh /path/to/LabProject_FrontendBackend 100

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

for command in node python3 git grep find sed awk realpath wc tr sort dirname basename; do
  command -v "$command" >/dev/null 2>&1 || {
    if command -v node >/dev/null 2>&1; then
      json_error "Required grading tool is missing: $command"
    fi
    printf '%s\n' "{\"score\":0,\"feedback\":\"Required grading tool is missing: $command\"}"
    exit 0
  }
done

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
project_dir=""

is_project_root() {
  local candidate="$1"
  [[ -f "$candidate/main.tf" && -d "$candidate/ansible" ]]
}

if is_project_root "$submission_dir"; then
  project_dir="$submission_dir"
else
  while IFS= read -r main_file; do
    candidate="$(dirname "$main_file")"
    if is_project_root "$candidate"; then
      project_dir="$(realpath "$candidate")"
      break
    fi
  done < <(find "$submission_dir" -maxdepth 5 -type f -name main.tf -not -path '*/.terraform/*' 2>/dev/null | sort)
fi

if [[ -z "$project_dir" ]]; then
  json_error "Lab 15 project root was not found. Expected main.tf and an ansible directory inside the submitted path."
fi

tf_has() {
  local pattern="$1"
  local -a files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$project_dir" -type f -name '*.tf' -not -path '*/.terraform/*' -print0 2>/dev/null)
  (( ${#files[@]} > 0 )) && grep -Eiq -- "$pattern" "${files[@]}" 2>/dev/null
}

ansible_has() {
  local pattern="$1"
  [[ -d "$project_dir/ansible" ]] || return 1
  local -a files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$project_dir/ansible" -type f \
    \( -name '*.yml' -o -name '*.yaml' -o -name '*.j2' -o -name '*.cfg' -o -name '*.ini' -o -name '*.html' \) \
    -print0 2>/dev/null)
  (( ${#files[@]} > 0 )) && grep -Eiq -- "$pattern" "${files[@]}" 2>/dev/null
}

tree_has() {
  local root="$1"
  local pattern="$2"
  [[ -d "$root" ]] || return 1
  local -a files=()
  while IFS= read -r -d '' file; do
    files+=("$file")
  done < <(find "$root" -type f \
    \( -name '*.yml' -o -name '*.yaml' -o -name '*.j2' -o -name '*.cfg' -o -name '*.ini' -o -name '*.html' \) \
    -print0 2>/dev/null)
  (( ${#files[@]} > 0 )) && grep -Eiq -- "$pattern" "${files[@]}" 2>/dev/null
}

file_has() {
  local file="$1"
  local pattern="$2"
  [[ -f "$file" ]] && grep -Eiq -- "$pattern" "$file" 2>/dev/null
}

all_tf_patterns() {
  local pattern
  for pattern in "$@"; do
    tf_has "$pattern" || return 1
  done
}

all_tree_patterns() {
  local root="$1"
  shift
  local pattern
  for pattern in "$@"; do
    tree_has "$root" "$pattern" || return 1
  done
}

find_role() {
  local exact_name="$1"
  local alternative_pattern="$2"
  local roles_root="$project_dir/ansible/roles"
  local candidate

  if [[ -d "$roles_root/$exact_name" ]]; then
    realpath "$roles_root/$exact_name"
    return 0
  fi

  if [[ -d "$roles_root" ]]; then
    while IFS= read -r candidate; do
      if basename "$candidate" | grep -Eiq -- "$alternative_pattern"; then
        realpath "$candidate"
        return 0
      fi
    done < <(find "$roles_root" -mindepth 1 -maxdepth 1 -type d | sort)
  fi

  return 1
}

frontend_role="$(find_role frontend '(front|nginx)' 2>/dev/null || true)"
backend_role="$(find_role backend '(back|httpd|apache)' 2>/dev/null || true)"

raw_score=0
possible_score=0
feedback=()

record_result() {
  local points="$1"
  local passed="$2"
  local label="$3"
  possible_score=$((possible_score + points))

  if [[ "$passed" == true ]]; then
    raw_score=$((raw_score + points))
    feedback+=("$label: passed (+$points/$points)")
  else
    feedback+=("$label: missing or incomplete (+0/$points)")
  fi
}

# ---------------------------------------------------------------------------
# A. Terraform Infrastructure Design — 25 marks
# ---------------------------------------------------------------------------

if all_tf_patterns \
  'resource[[:space:]]+"aws_vpc"|module[[:space:]]+"[^" ]*vpc' \
  'vpc_cidr_block' \
  'cidr_block[[:space:]]*=[[:space:]]*var[.]vpc_cidr_block'; then
  record_result 2 true "A1 VPC uses the configured CIDR variable"
else
  record_result 2 false "A1 VPC uses the configured CIDR variable"
fi

if all_tf_patterns \
  'resource[[:space:]]+"aws_subnet"|module[[:space:]]+"[^" ]*subnet' \
  'subnet_cidr_block' \
  'map_public_ip_on_launch[[:space:]]*=[[:space:]]*true|associate_public_ip_address[[:space:]]*=[[:space:]]*true'; then
  record_result 2 true "A1 Public subnet configuration"
else
  record_result 2 false "A1 Public subnet configuration"
fi

if all_tf_patterns \
  'aws_internet_gateway' \
  'aws_(default_)?route_table|aws_route' \
  '0[.]0[.]0[.]0/0'; then
  record_result 2 true "A1 Internet gateway and default route"
else
  record_result 2 false "A1 Internet gateway and default route"
fi

required_variables=(
  vpc_cidr_block subnet_cidr_block availability_zone env_prefix
  instance_type public_key private_key
)
variables_ok=true
for variable_name in "${required_variables[@]}"; do
  tf_has "variable[[:space:]]+\"$variable_name\"" || variables_ok=false
done
if [[ "$variables_ok" == true ]] && all_tf_patterns \
  'locals[[:space:]]*\{' \
  'data[[:space:]]+"http"[[:space:]]+"my_ip"' \
  'icanhazip[.]com' \
  'local[.]my_ip'; then
  record_result 2 true "A1 Required variables and Codespace public-IP local"
else
  record_result 2 false "A1 Required variables and Codespace public-IP local"
fi

if tf_has 'resource[[:space:]]+"aws_(default_)?security_group"'; then
  record_result 1 true "A2 Security group resource"
else
  record_result 1 false "A2 Security group resource"
fi

if all_tf_patterns \
  'from_port[[:space:]]*=[[:space:]]*22' \
  'to_port[[:space:]]*=[[:space:]]*22' \
  'cidr_blocks[[:space:]]*=[[:space:]]*\[[[:space:]]*local[.]my_ip'; then
  record_result 3 true "A2 SSH limited to the student's public IP"
else
  record_result 3 false "A2 SSH limited to the student's public IP"
fi

if all_tf_patterns \
  'from_port[[:space:]]*=[[:space:]]*80' \
  'to_port[[:space:]]*=[[:space:]]*80' \
  'cidr_blocks[[:space:]]*=[[:space:]]*\[[[:space:]]*"0[.]0[.]0[.]0/0"'; then
  record_result 3 true "A2 HTTP ingress from the Internet"
else
  record_result 3 false "A2 HTTP ingress from the Internet"
fi

if tf_has '(resource[[:space:]]+"aws_instance"[[:space:]]+"[^" ]*front|module[[:space:]]+"[^" ]*front)' && \
   tf_has '(name|Name)[[:space:]]*=[[:space:]]*"?[$]{?var[.]env_prefix}?-frontend'; then
  record_result 3 true "A3 One meaningfully tagged frontend instance"
else
  record_result 3 false "A3 One meaningfully tagged frontend instance"
fi

if tf_has '(resource[[:space:]]+"aws_instance"[[:space:]]+"[^" ]*back|module[[:space:]]+"[^" ]*back|module[[:space:]]+"[^" ]*webserver)' && \
   tf_has 'count[[:space:]]*=[[:space:]]*3' && \
   tf_has '(backend|instance_suffix).*(count[.]index)|count[.]index.*(backend|instance_suffix)'; then
  record_result 4 true "A3 Three independently tagged backend instances"
else
  record_result 4 false "A3 Three independently tagged backend instances"
fi

if all_tf_patterns \
  'aws_key_pair|key_name' \
  'security_group|vpc_security_group_ids' \
  'output[[:space:]]+"frontend_public_ip' \
  'output[[:space:]]+"backend_public_ips' \
  'output[[:space:]]+"backend_private_ips'; then
  record_result 3 true "A3 SSH key, security group, and required IP outputs"
else
  record_result 3 false "A3 SSH key, security group, and required IP outputs"
fi

# ---------------------------------------------------------------------------
# B. Ansible Roles & Playbook Structure — 25 marks
# ---------------------------------------------------------------------------

if [[ -n "$frontend_role" && -n "$backend_role" ]]; then
  record_result 4 true "B1 Separate frontend and backend role directories"
else
  record_result 4 false "B1 Separate frontend and backend role directories"
fi

if ansible_has 'roles[[:space:]]*:' && \
   ansible_has '(^|[[:space:]-])frontend([[:space:]]|$)' && \
   ansible_has '(^|[[:space:]-])backend([[:space:]]|$)' && \
   ansible_has 'hosts[[:space:]]*:[[:space:]]*front' && \
   ansible_has 'hosts[[:space:]]*:[[:space:]]*back'; then
  record_result 4 true "B1 Main playbook targets both groups through roles"
else
  record_result 4 false "B1 Main playbook targets both groups through roles"
fi

if [[ -n "$backend_role" ]] && all_tree_patterns "$backend_role" \
  'name[[:space:]]*:[[:space:]]*httpd|name[[:space:]]*:[[:space:]]*apache' \
  'state[[:space:]]*:[[:space:]]*present' \
  'state[[:space:]]*:[[:space:]]*started' \
  'enabled[[:space:]]*:[[:space:]]*true' \
  'template[[:space:]]*:' \
  '/var/www/html/index[.]html'; then
  record_result 5 true "B2 Backend role installs, starts, and templates HTTPD"
else
  record_result 5 false "B2 Backend role installs, starts, and templates HTTPD"
fi

if [[ -n "$frontend_role" ]] && all_tree_patterns "$frontend_role" \
  'name[[:space:]]*:[[:space:]]*nginx' \
  'state[[:space:]]*:[[:space:]]*present' \
  'state[[:space:]]*:[[:space:]]*started' \
  'enabled[[:space:]]*:[[:space:]]*true' \
  'template[[:space:]]*:' \
  '/etc/nginx/nginx[.]conf'; then
  record_result 5 true "B2 Frontend role installs, starts, and templates Nginx"
else
  record_result 5 false "B2 Frontend role installs, starts, and templates Nginx"
fi

backend_template_count=0
frontend_template_count=0
[[ -n "$backend_role" && -d "$backend_role/templates" ]] && \
  backend_template_count="$(find "$backend_role/templates" -type f | wc -l | tr -d '[:space:]')"
[[ -n "$frontend_role" && -d "$frontend_role/templates" ]] && \
  frontend_template_count="$(find "$frontend_role/templates" -type f | wc -l | tr -d '[:space:]')"
if (( backend_template_count > 0 && frontend_template_count > 0 )); then
  record_result 2 true "B3 Both roles contain templates"
else
  record_result 2 false "B3 Both roles contain templates"
fi

if [[ -n "$backend_role" && -f "$backend_role/handlers/main.yml" || -f "$backend_role/handlers/main.yaml" ]] && \
   [[ -n "$frontend_role" && -f "$frontend_role/handlers/main.yml" || -f "$frontend_role/handlers/main.yaml" ]] && \
   tree_has "$frontend_role" 'notify[[:space:]]*:[[:space:]]*restart[[:space:]]+nginx'; then
  record_result 2 true "B3 Role handlers and notification wiring"
else
  record_result 2 false "B3 Role handlers and notification wiring"
fi

if { [[ -n "$frontend_role" && -d "$frontend_role/defaults" ]] || [[ -n "$frontend_role" && -d "$frontend_role/vars" ]]; } && \
   { [[ -n "$backend_role" && -d "$backend_role/defaults" ]] || [[ -n "$backend_role" && -d "$backend_role/vars" ]]; }; then
  record_result 1 true "B3 Role defaults or variables directories"
else
  record_result 1 false "B3 Role defaults or variables directories"
fi

if [[ -n "$frontend_role" && -s "$frontend_role/tasks/main.yml" || -s "$frontend_role/tasks/main.yaml" ]] && \
   [[ -n "$backend_role" && -s "$backend_role/tasks/main.yml" || -s "$backend_role/tasks/main.yaml" ]]; then
  record_result 1 true "B3 Non-empty task entry points"
else
  record_result 1 false "B3 Non-empty task entry points"
fi

if ansible_has 'configure.*backend' && ansible_has 'configure.*frontend'; then
  record_result 1 true "B3 Clearly separated frontend and backend plays"
else
  record_result 1 false "B3 Clearly separated frontend and backend plays"
fi

# ---------------------------------------------------------------------------
# C. Nginx Frontend + Backend HTTPD Behavior — 25 marks
# ---------------------------------------------------------------------------

if [[ -n "$backend_role" ]] && all_tree_patterns "$backend_role" \
  '(httpd|apache)' \
  'state[[:space:]]*:[[:space:]]*started' \
  'template[[:space:]]*:' \
  '/var/www/html/index[.]html'; then
  record_result 3 true "C1 HTTPD service and backend page deployment"
else
  record_result 3 false "C1 HTTPD service and backend page deployment"
fi

if [[ -n "$backend_role" ]] && tree_has "$backend_role" 'inventory_hostname|ansible_hostname'; then
  record_result 3 true "C1 Distinct backend identity in rendered content"
else
  record_result 3 false "C1 Distinct backend identity in rendered content"
fi

if [[ -n "$backend_role" ]] && tree_has "$backend_role" 'ansible_default_ipv4[.]address|private[[:space:]]+ip'; then
  record_result 2 true "C1 Backend page includes private-IP evidence"
else
  record_result 2 false "C1 Backend page includes private-IP evidence"
fi

if [[ -n "$frontend_role" ]] && all_tree_patterns "$frontend_role" \
  'upstream[[:space:]]+backend' \
  'proxy_pass[[:space:]]+http://backend'; then
  record_result 4 true "C2 Nginx upstream and reverse proxy"
else
  record_result 4 false "C2 Nginx upstream and reverse proxy"
fi

if ansible_has 'backend1_private_ip|groups\[[^]]*backends[^]]*\]|hostvars\[' && \
   ansible_has 'backend2_private_ip|groups\[[^]]*backends[^]]*\]' && \
   ansible_has 'backup_backend_private_ip|groups\[[^]]*backends[^]]*\]'; then
  record_result 3 true "C2 Frontend receives backend private addresses dynamically"
else
  record_result 3 false "C2 Frontend receives backend private addresses dynamically"
fi

if [[ -n "$frontend_role" ]] && tree_has "$frontend_role" 'proxy_set_header[[:space:]]+(host|x-real-ip|x-forwarded-for)'; then
  record_result 1 true "C2 Reverse-proxy forwarding headers"
else
  record_result 1 false "C2 Reverse-proxy forwarding headers"
fi

nginx_server_count=0
nginx_backup_count=0
nginx_primary_count=0
if [[ -n "$frontend_role" && -d "$frontend_role/templates" ]]; then
  nginx_server_count="$(
    find "$frontend_role/templates" -type f -exec grep -hEi '^[[:space:]]*server[[:space:]]+.*:80([[:space:]]+backup)?[[:space:]]*;' {} + 2>/dev/null |
      wc -l | tr -d '[:space:]'
  )"
  nginx_backup_count="$(
    find "$frontend_role/templates" -type f -exec grep -hEi '^[[:space:]]*server[[:space:]]+.*:80[[:space:]]+backup[[:space:]]*;' {} + 2>/dev/null |
      wc -l | tr -d '[:space:]'
  )"
  nginx_primary_count=$((nginx_server_count - nginx_backup_count))
fi

if (( nginx_server_count >= 3 )); then
  record_result 3 true "C3 At least three Nginx upstream server entries"
else
  record_result 3 false "C3 At least three Nginx upstream server entries"
fi

if (( nginx_primary_count >= 2 )); then
  record_result 3 true "C3 Two primary upstream backends"
else
  record_result 3 false "C3 Two primary upstream backends"
fi

if (( nginx_backup_count >= 1 )); then
  record_result 3 true "C3 One explicitly configured backup backend"
else
  record_result 3 false "C3 One explicitly configured backup backend"
fi

# ---------------------------------------------------------------------------
# D. Terraform–Ansible Automation & Idempotence — 15 marks
# ---------------------------------------------------------------------------

if tf_has 'resource[[:space:]]+"null_resource"'; then
  record_result 2 true "D1 Terraform null_resource automation"
else
  record_result 2 false "D1 Terraform null_resource automation"
fi

if all_tf_patterns 'triggers[[:space:]]*\{' 'depends_on[[:space:]]*=' '(frontend|backend).*ip'; then
  record_result 2 true "D1 IP triggers and EC2 dependencies"
else
  record_result 2 false "D1 IP triggers and EC2 dependencies"
fi

if all_tf_patterns 'provisioner[[:space:]]+"local-exec"' 'ansible-playbook' '(site[.]ya?ml|playbook[.]ya?ml)'; then
  record_result 4 true "D1 local-exec automatically starts the role playbook"
else
  record_result 4 false "D1 local-exec automatically starts the role playbook"
fi

if tf_has 'templatefile|local_file|generated_hosts|inventory/hosts|generated_hosts[.]ini' && \
   tf_has 'frontend.*ip|backend.*ips'; then
  record_result 2 true "D2 Inventory or host data generated for all tiers"
else
  record_result 2 false "D2 Inventory or host data generated for all tiers"
fi

if ansible_has 'wait_for[[:space:]]*:' || tf_has '(sleep[[:space:]]+[0-9]+|wait_for|connection[[:space:]]+timeout)'; then
  record_result 1 true "D2 Readiness handling before Ansible configuration"
else
  record_result 1 false "D2 Readiness handling before Ansible configuration"
fi

if all_tf_patterns 'resource[[:space:]]+"null_resource"' 'local-exec' 'ansible-playbook' 'depends_on'; then
  record_result 1 true "D2 Single-apply provisioning and configuration path"
else
  record_result 1 false "D2 Single-apply provisioning and configuration path"
fi

if ansible_has '(yum|package)[[:space:]]*:' && ansible_has 'service[[:space:]]*:' && ansible_has 'template[[:space:]]*:'; then
  record_result 2 true "D3 Idempotent package, service, and template modules"
else
  record_result 2 false "D3 Idempotent package, service, and template modules"
fi

core_shell_usage=false
if [[ -n "$frontend_role" ]] && tree_has "$frontend_role" '^[[:space:]]*(shell|command)[[:space:]]*:'; then
  core_shell_usage=true
fi
if [[ -n "$backend_role" ]] && tree_has "$backend_role" '^[[:space:]]*(shell|command)[[:space:]]*:'; then
  core_shell_usage=true
fi
if [[ -n "$frontend_role" && -n "$backend_role" && "$core_shell_usage" == false ]]; then
  record_result 1 true "D3 No shell commands for core role package/service work"
else
  record_result 1 false "D3 No shell commands for core role package/service work"
fi

# ---------------------------------------------------------------------------
# E. Code Quality, Documentation & Git Usage — 10 marks
# ---------------------------------------------------------------------------

root_tf_files_ok=true
for required_file in main.tf variables.tf outputs.tf locals.tf; do
  [[ -s "$project_dir/$required_file" ]] || root_tf_files_ok=false
done
if [[ "$root_tf_files_ok" == true ]]; then
  record_result 2 true "E1 Required non-empty Terraform root files"
else
  record_result 2 false "E1 Required non-empty Terraform root files"
fi

if [[ -d "$project_dir/modules/subnet" ]] && \
   find "$project_dir/modules/subnet" -type f -name '*.tf' | grep -q .; then
  record_result 1 true "E1 Reusable Terraform subnet module"
else
  record_result 1 false "E1 Reusable Terraform subnet module"
fi

if [[ -d "$project_dir/ansible/playbooks" && -d "$project_dir/ansible/roles" ]] && \
   [[ -f "$project_dir/ansible/ansible.cfg" ]]; then
  record_result 1 true "E1 Production-like Ansible directory structure"
else
  record_result 1 false "E1 Production-like Ansible directory structure"
fi

if tf_has 'description[[:space:]]*=' && tf_has '(env_prefix|frontend|backend)' && ansible_has 'name[[:space:]]*:'; then
  record_result 1 true "E1 Descriptive variables, task names, and tier naming"
else
  record_result 1 false "E1 Descriptive variables, task names, and tier naming"
fi

readme_file=""
for candidate in "$project_dir/README.md" "$project_dir/readme.md" "$project_dir/README.MD"; do
  if [[ -f "$candidate" ]]; then
    readme_file="$candidate"
    break
  fi
done

if [[ -n "$readme_file" && -s "$readme_file" ]]; then
  record_result 1 true "E2 README documentation exists"
else
  record_result 1 false "E2 README documentation exists"
fi

if [[ -n "$readme_file" ]] && file_has "$readme_file" 'terraform[[:space:]]+init' && \
   file_has "$readme_file" 'terraform[[:space:]]+apply[[:space:]]+-auto-approve'; then
  record_result 1 true "E2 README includes run commands"
else
  record_result 1 false "E2 README includes run commands"
fi

if [[ -n "$readme_file" ]] && file_has "$readme_file" '(architecture|frontend|backend)' && \
   file_has "$readme_file" '(assumption|region|instance[[:space:]]+type|ami)'; then
  record_result 1 true "E2 README explains architecture and assumptions"
else
  record_result 1 false "E2 README explains architecture and assumptions"
fi

gitignore_file="$project_dir/.gitignore"
if [[ -f "$gitignore_file" ]] && \
   file_has "$gitignore_file" '[.]terraform' && \
   file_has "$gitignore_file" '[*][.]tfstate' && \
   file_has "$gitignore_file" '[*][.]tfvars' && \
   file_has "$gitignore_file" '[*][.]pem'; then
  record_result 1 true "E3 .gitignore protects generated and sensitive files"
else
  record_result 1 false "E3 .gitignore protects generated and sensitive files"
fi

repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null || true)"
tracked_sensitive=""
tracked_project_files=""
if [[ -n "$repo_root" ]]; then
  tracked_project_files="$(git -C "$project_dir" ls-files -- . 2>/dev/null || true)"
  tracked_sensitive="$(
    printf '%s\n' "$tracked_project_files" |
      grep -Ei '(^|/)(terraform[.]tfstate([.].*)?|[^/]*[.]tfstate([.].*)?|terraform[.]tfvars|[^/]*[.]pem|id_ed25519|[.]env|[.]aws/credentials)$' || true
  )"
fi

content_secret_found=false
if find "$project_dir" -type f \
  \( -name '*.tf' -o -name '*.tfvars' -o -name '*.yml' -o -name '*.yaml' -o -name '*.ini' -o -name '*.cfg' -o -name '*.sh' -o -name '.env' \) \
  -not -path '*/.git/*' -not -path '*/.terraform/*' \
  -exec grep -EIl '(BEGIN.*PRIVATE[[:space:]]+KEY|(AKIA|ASIA)[0-9A-Z]{16}|ghp_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9A-Za-z/+=]{20,})' {} + 2>/dev/null |
  grep -q .; then
  content_secret_found=true
fi

if [[ -n "$tracked_project_files" && -z "$tracked_sensitive" && "$content_secret_found" == false ]]; then
  record_result 1 true "E3 No tracked state, private keys, tfvars, or recognizable credentials"
else
  record_result 1 false "E3 No tracked state, private keys, tfvars, or recognizable credentials"
  [[ -n "$tracked_sensitive" ]] && feedback+=("Security warning: tracked sensitive/generated paths: $(tr '\n' ',' <<<"$tracked_sensitive" | sed 's/,$//')")
  [[ "$content_secret_found" == true ]] && feedback+=("Security warning: recognizable credential material was found in project code")
fi

if (( possible_score != 100 )); then
  json_error "Internal grader error: rubric totals $possible_score instead of 100."
fi

scaled_score="$(python3 - "$raw_score" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

raw = Decimal(sys.argv[1])
total = Decimal(sys.argv[2])
value = (raw / Decimal("100") * total).quantize(
    Decimal("0.01"),
    rounding=ROUND_HALF_UP,
)
print(value)
PY
)"

summary="Lab 15 static project assessment: raw rubric score $raw_score/100; project root: ${project_dir#"$submission_dir"/}. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$scaled_score" "$summary"
