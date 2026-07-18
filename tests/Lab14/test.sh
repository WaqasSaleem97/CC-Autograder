#!/usr/bin/env bash
set -u

# Grade Lab 14 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab14/test.sh \
#     work/submissions/Student/CC/Labs/Lab14 \
#     10
#
# Manual example:
#   bash tests/Lab14/test.sh /path/to/CC/Labs/Lab14 10 waqassaleem97

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
  json_error "Required directory is missing: Labs/Lab14/screenshots"
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
#   none      - no terminal identity requirement (editor/browser evidence)
#   codespace - GitHub username, /workspaces path, or Codespaces context required
#   ec2       - an ec2-user@<host> terminal prompt must appear
readarray -t criteria <<'EOF'
task0_codespace_open.png|none|(codespaces|github);;terraform_machine;;(visual[[:space:]]+studio[[:space:]]+code|codespace|/workspaces/)
task0_env_check.png|codespace|aws[[:space:]]+--version;;terraform[[:space:]]+--version;;ansible[[:space:]]+--version;;(aws-cli|terraform[[:space:]]+v|ansible.*core|not[[:space:]]+yet[[:space:]]+installed)
task0_aws_config.png|codespace|aws[[:space:]]+sts[[:space:]]+get-caller-identity;;userid;;account;;arn:aws:(iam|sts)
task1_ssh_keygen_before.png|codespace|ls[[:space:]]+.*[.]ssh
task1_ssh_keygen.png|codespace|ssh-keygen;;ed25519;;id_ed25519;;(fingerprint|randomart|public[[:space:]]+key)
task1_ssh_keygen_after.png|codespace|ls[[:space:]]+-la[[:space:]]+.*[.]ssh;;id_ed25519;;id_ed25519[.]pub
task1_terraform_tfvars_created.png|codespace|touch[[:space:]]+terraform[.]tfvars;;ls[[:space:]]+-la[[:space:]]+terraform[.]tfvars
task1_terraform_tfvars.png|none|vpc_cidr_block;;10[.]0[.]0[.]0/16;;subnet_cidr_block;;10[.]0[.]10[.]0/24;;me-central;;instance_type;;micro;;id_ed25519
task1_terraform_init.png|codespace|terraform[[:space:]]+init;;successfully[[:space:]]+initialized;;(hashicorp/aws|provider)
task1_terraform_apply_2_instances.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;module[.]myapp-webserver;;(aws_instance|creation[[:space:]]+complete);;(\[0\]|\[1\]|2[[:space:]]+added)
task1_terraform_output_ips.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task2_ansible_install.png|codespace|pipx[[:space:]]+install[[:space:]]+ansible-core;;ansible[[:space:]]+--version;;ansible.*core
task2_terraform_output_ips.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task2_hosts_created.png|codespace|touch[[:space:]]+hosts;;ls[[:space:]]+-la[[:space:]]+hosts
task2_hosts_initial.png|none|[0-9]{1,3}([.][0-9]{1,3}){3};;ansible_user[[:space:]]*=[[:space:]]*ec2-user;;ansible_ssh_private_key_file;;id_ed25519
task2_ansible_ping_initial.png|codespace|ansible[[:space:]]+all[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;(success|pong|unreachable|failed|permission[[:space:]]+denied|host[[:space:]]+key)
task2_hosts_with_common_args.png|none|ansible_ssh_common_args;;stricthostkeychecking=no;;ansible_user[[:space:]]*=[[:space:]]*ec2-user;;id_ed25519
task2_ansible_ping_success.png|codespace|ansible[[:space:]]+all[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task3_main_tf_count_3.png|none|module[[:space:]]+"myapp-webserver";;count[[:space:]]*=[[:space:]]*3;;instance_suffix[[:space:]]*=[[:space:]]*count[.]index
task3_terraform_apply_3_instances.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;module[.]myapp-webserver;;(\[2\]|3[[:space:]]+added|creation[[:space:]]+complete)
task3_terraform_output_3_ips.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task3_hosts_grouped.png|none|\[ec2\];;\[ec2:vars\];;\[droplet\];;\[droplet:vars\];;ec2-user;;id_ed25519
task3_ansible_ec2_ping.png|codespace|ansible[[:space:]]+ec2[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task3_ansible_single_ip_ping.png|codespace|ansible[[:space:]]+[0-9]{1,3}([.][0-9]{1,3}){3}[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task3_ansible_droplet_ping.png|codespace|ansible[[:space:]]+droplet[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task3_ansible_all_ping.png|codespace|ansible[[:space:]]+all[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task4_global_ansible_cfg.png|none|\[default(s)?\];;host_key_checking[[:space:]]*=[[:space:]]*false;;interpreter_python[[:space:]]*=[[:space:]]*/usr/bin/python3
task4_hosts_without_common_args.png|none|\[ec2\];;\[droplet\];;ansible_user[[:space:]]*=[[:space:]]*ec2-user;;ansible_ssh_private_key_file
task4_ansible_ping_after_cfg.png|codespace|ansible[[:space:]]+all[[:space:]]+-i[[:space:]]+hosts[[:space:]]+-m[[:space:]]+ping;;success;;pong
task4_my_playbook_created.png|codespace|touch[[:space:]]+my-playbook[.]yaml;;ls[[:space:]]+-la[[:space:]]+my-playbook[.]yaml
task4_my_playbook_ec2.png|none|configure[[:space:]]+nginx[[:space:]]+web[[:space:]]+server;;hosts:[[:space:]]*ec2;;become:[[:space:]]*true;;yum:;;name:[[:space:]]*nginx;;service:
task4_ansible_play_ec2.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;(ok=|changed=);;(failed=0|unreachable=0)
task4_nginx_browser_ec2.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task4_my_playbook_droplet.png|none|configure[[:space:]]+nginx[[:space:]]+web[[:space:]]+server;;hosts:[[:space:]]*droplet;;become:[[:space:]]*true;;nginx
task4_ansible_play_droplet.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;(ok=|changed=);;(failed=0|unreachable=0)
task4_nginx_browser_droplet.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task5_project_ansible_cfg_created.png|codespace|touch[[:space:]]+ansible[.]cfg;;ls[[:space:]]+-la[[:space:]]+ansible[.]cfg
task5_project_ansible_cfg.png|none|\[defaults\];;host_key_checking[[:space:]]*=[[:space:]]*false;;interpreter_python[[:space:]]*=[[:space:]]*/usr/bin/python3
task5_main_tf_count_1.png|none|module[[:space:]]+"myapp-webserver";;count[[:space:]]*=[[:space:]]*1;;instance_suffix
task5_terraform_apply_one_instance.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;module[.]myapp-webserver;;(aws_instance|creation[[:space:]]+complete)
task5_terraform_output_single_ip.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task5_hosts_nginx_group.png|none|\[nginx\];;\[nginx:vars\];;ansible_ssh_private_key_file;;id_ed25519;;ansible_user[[:space:]]*=[[:space:]]*ec2-user
task5_my_playbook_nginx_group.png|none|configure[[:space:]]+nginx[[:space:]]+web[[:space:]]+server;;hosts:[[:space:]]*nginx;;name:[[:space:]]*openssl;;name:[[:space:]]*nginx;;enabled:[[:space:]]*true
task5_ansible_play_nginx_group.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;(ok=|changed=);;(failed=0|unreachable=0)
task5_nginx_browser_single.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task6_my_playbook_ssl_section.png|none|configure[[:space:]]+ssl[[:space:]]+certificates;;hosts:[[:space:]]*nginx;;imdsv2;;openssl[[:space:]]+req;;selfsigned[.]key;;selfsigned[.]crt
task6_ansible_play_ssl.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;configure[[:space:]]+ssl;;(generate[[:space:]]+self-signed|self-signed[[:space:]]+ssl);;play[[:space:]]+recap;;failed=0
task6_ssl_cert_file.png|ec2|/etc/ssl/certs/selfsigned[.]crt;;begin[[:space:]]+certificate
task6_ssl_key_file.png|ec2|/etc/ssl/private/selfsigned[.]key;;(ls[[:space:]]+-l|permissions|[-]rw|openssl[[:space:]]+pkey);;(key[[:space:]]+is[[:space:]]+valid|0700|0600|root)
task7_files_templates_created.png|codespace|(ls[[:space:]]+-r|files|templates);;files;;index[.]php;;templates;;nginx[.]conf[.]j2
task7_index_php_content.png|none|getimds(v2)?token;;getmetadata;;instance-id;;local-ipv4;;public-ipv4;;frontend[[:space:]]+web[[:space:]]+server;;terraform[[:space:]]+[+]?[[:space:]]*ansible
task7_nginx_conf_template.png|none|listen[[:space:]]+443[[:space:]]+ssl;;server_public_ip;;selfsigned[.]crt;;selfsigned[.]key;;fastcgi_pass;;php-fpm;;return[[:space:]]+301[[:space:]]+https
task7_my_playbook_web_deploy.png|none|deploy[[:space:]]+nginx[[:space:]]+website;;hosts:[[:space:]]*nginx;;php-fpm;;files/index[.]php;;templates/nginx[.]conf[.]j2;;restart[[:space:]]+nginx
task7_ansible_play_web_deploy.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;(php-fpm|copy[[:space:]]+website|nginx[.]conf);;play[[:space:]]+recap;;failed=0
task7_php_https_browser.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;nginx[[:space:]]+front[[:space:]]+end[[:space:]]+web[[:space:]]+server;;hostname;;instance[[:space:]]+id;;managed[[:space:]]+by;;terraform[[:space:]]+[+]?[[:space:]]*ansible
task8_terraform_destroy_old.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
task8_terraform_apply_docker_instance.png|codespace|terraform[[:space:]]+apply;;apply[[:space:]]+complete;;module[.]myapp-webserver;;(added|creation[[:space:]]+complete)
task8_terraform_output_new_ip.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task8_hosts_docker_servers.png|none|\[docker_servers\];;\[docker_servers:vars\];;ansible_ssh_private_key_file;;id_ed25519;;ansible_user[[:space:]]*=[[:space:]]*ec2-user
task8_my_playbook_docker.png|none|configure[[:space:]]+docker;;hosts:[[:space:]]*all;;name:[[:space:]]*docker;;docker[[:space:]]+compose;;cli-plugins;;docker-compose;;restart[[:space:]]+docker
task8_ansible_play_docker.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;(install[[:space:]]+docker|docker-compose|docker[[:space:]]+compose);;play[[:space:]]+recap;;failed=0
task8_docker_ps_remote.png|ec2|sudo[[:space:]]+docker[[:space:]]+ps;;container[[:space:]]+id;;image;;status
task9_my_playbook_add_user_to_docker.png|none|adding[[:space:]]+user[[:space:]]+to[[:space:]]+docker[[:space:]]+group;;normal_user;;groups:[[:space:]]*docker;;reset_connection;;docker[[:space:]]+ps
task9_project_vars.png|none|normal_user:[[:space:]]*ec2-user;;docker_compose_file_location
task9_my_playbook_deploy_containers.png|none|deploy[[:space:]]+docker[[:space:]]+containers;;project-vars[.]yaml;;compose[.]yaml;;docker[[:space:]]+compose[[:space:]]+up[[:space:]]+-d
task9_compose_yaml.png|none|services:;;gitea:;;gitea/gitea;;db:;;postgres:alpine;;db_passwd;;postgres_password;;3000:3000;;webnet
task9_ansible_play_gitea.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+hosts[[:space:]]+my-playbook[.]yaml;;(gitea|deploy[[:space:]]+containers|docker[[:space:]]+compose);;play[[:space:]]+recap;;failed=0
task9_sg_ingress_3000.png|none|ingress;;from_port[[:space:]]*=[[:space:]]*3000;;to_port[[:space:]]*=[[:space:]]*3000;;protocol[[:space:]]*=[[:space:]]*"tcp";;0[.]0[.]0[.]0/0
task9_terraform_apply_sg_3000.png|codespace|terraform[[:space:]]+apply;;(aws_security_group|web_sg);;(3000|ingress);;apply[[:space:]]+complete
task9_gitea_browser.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3}:3000;;gitea;;(initial[[:space:]]+configuration|sign[[:space:]]+in|register|database)
task10_null_resource_main_tf.png|none|null_resource;;configure_server;;webserver_public_ips_for_ansible;;local-exec;;ansible-playbook;;private-key;;ec2-user
task10_terraform_destroy_before_null.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
task10_terraform_apply_with_local_exec.png|codespace|terraform[[:space:]]+apply;;null_resource[.]configure_server;;local-exec;;ansible-playbook;;(play[[:space:]]+recap|apply[[:space:]]+complete)
task10_my_playbook_wait_for_ssh.png|none|wait[[:space:]]+for[[:space:]]+some[[:space:]]+time;;hosts:[[:space:]]*all;;wait_for:;;port:[[:space:]]*22;;timeout:[[:space:]]*300;;delegate_to:[[:space:]]*localhost
task10_terraform_apply_after_wait.png|codespace|terraform[[:space:]]+apply;;(wait[[:space:]]+300[[:space:]]+seconds|wait_for|port[[:space:]]+22);;(play[[:space:]]+recap|apply[[:space:]]+complete);;(failed=0|unreachable=0)
task10_app_browser_post_null_resource.png|none|http(s)?://[0-9]{1,3}([.][0-9]{1,3}){3}(:3000)?;;(gitea|nginx|front[[:space:]]+end[[:space:]]+web[[:space:]]+server)
task11_ansible_cfg_aws_ec2.png|none|\[defaults\];;enable_plugins[[:space:]]*=[[:space:]]*aws_ec2;;private_key_file;;id_ed25519;;deprecation_warnings[[:space:]]*=[[:space:]]*false
task11_inventory_aws_ec2_created.png|codespace|touch[[:space:]]+inventory_aws_ec2[.]yaml;;ls[[:space:]]+-la[[:space:]]+inventory_aws_ec2[.]yaml
task11_inventory_aws_ec2_initial.png|none|plugin:[[:space:]]*aws_ec2;;regions:;;me-central-1
task11_main_tf_dev_prod_modules.png|none|module[[:space:]]+"myapp-webserver";;env_prefix;;count[[:space:]]*=[[:space:]]*1;;module[[:space:]]+"myapp-webserver-prod";;env_prefix[[:space:]]*=[[:space:]]*"prod";;t3[.]nano
task11_outputs_tf_dev_prod_ips.png|none|output[[:space:]]+"webserver_public_ips";;module[.]myapp-webserver;;output[[:space:]]+"prod-webserver_public_ips";;module[.]myapp-webserver-prod;;public_ip
task11_terraform_apply_dynamic_setup.png|codespace|terraform[[:space:]]+apply;;module[.]myapp-webserver;;module[.]myapp-webserver-prod;;apply[[:space:]]+complete;;added
task11_terraform_output_dynamic_ips.png|codespace|terraform[[:space:]]+output;;webserver_public_ips;;prod-webserver_public_ips;;[0-9]{1,3}([.][0-9]{1,3}){3}
task11_boto_install.png|codespace|python.*-m[[:space:]]+pip[[:space:]]+install;;boto3;;botocore;;(successfully[[:space:]]+installed|requirement[[:space:]]+already[[:space:]]+satisfied)
task11_boto_version.png|codespace|import[[:space:]]+boto3;;botocore;;boto3[.]__version__;;[0-9]+[.][0-9]+
task11_ansible_inventory_graph_initial.png|codespace|ansible-inventory[[:space:]]+-i[[:space:]]+inventory_aws_ec2[.]yaml[[:space:]]+--graph;;@all;;@ungrouped;;(@aws_ec2|ec2)
task12_inventory_aws_ec2_tag_groups.png|none|plugin:[[:space:]]*aws_ec2;;keyed_groups:;;key:[[:space:]]*tags;;prefix:[[:space:]]*tag;;separator:[[:space:]]*"_"
task12_inventory_graph_tag_groups.png|codespace|ansible-inventory.*--graph;;@all;;(@tag|tag_name);;(dev|prod)
task12_inventory_aws_ec2_instance_type_groups.png|none|plugin:[[:space:]]*aws_ec2;;keyed_groups:;;key:[[:space:]]*tags;;prefix:[[:space:]]*tag;;key:[[:space:]]*instance_type;;prefix:[[:space:]]*instance_type
task12_inventory_graph_full.png|codespace|ansible-inventory.*--graph;;(@tag|tag_name);;(@instance_type|instance_type_t3);;(dev|prod);;(micro|nano)
task12_my_playbook_all_hosts.png|none|configure[[:space:]]+nginx;;hosts:[[:space:]]*all;;configure[[:space:]]+ssl;;deploy[[:space:]]+nginx[[:space:]]+website;;php-fpm;;selfsigned[.]crt
task12_ansible_play_all.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+inventory_aws_ec2[.]yaml;;my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task12_ansible_play_dev_only.png|codespace|ansible-playbook.*-l[[:space:]]+tag_name_dev_.*;;my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task12_ansible_play_prod_only.png|codespace|ansible-playbook.*-l[[:space:]]+tag_name_prod_.*;;my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task12_ansible_play_t3_micro.png|codespace|ansible-playbook.*-l[[:space:]]+instance_type_t3_micro;;my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task12_ansible_play_t3_nano.png|codespace|ansible-playbook.*-l[[:space:]]+instance_type_t3_nano;;my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task12_ansible_cfg_inventory_default.png|none|inventory[[:space:]]*=[[:space:]]*[.]?/inventory_aws_ec2[.]yaml;;\[defaults\]
task12_ansible_play_t3_nano_no_i.png|codespace|ansible-playbook[[:space:]]+-l[[:space:]]+instance_type_t3_nano[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task13_main_tf_single_dev.png|none|module[[:space:]]+"myapp-webserver";;env_prefix;;count[[:space:]]*=[[:space:]]*1;;instance_suffix[[:space:]]*=[[:space:]]*count[.]index
task13_ansible_structure_created.png|codespace|(ls[[:space:]]+-r|ansible);;ansible[.]cfg;;my-playbook[.]yaml;;inventory;;roles
task13_ansible_cfg_project.png|none|\[defaults\];;host_key_checking[[:space:]]*=[[:space:]]*false;;interpreter_python[[:space:]]*=[[:space:]]*/usr/bin/python3
task13_ansible_inventory_hosts.png|none|\[nginx\];;\[nginx:vars\];;ansible_ssh_private_key_file;;id_ed25519;;ansible_user[[:space:]]*=[[:space:]]*ec2-user
task13_roles_created.png|codespace|(ls[[:space:]]+-r|roles);;nginx;;ssl;;webapp;;defaults;;handlers;;tasks;;templates
task13_nginx_handlers_main.png|none|restart[[:space:]]+nginx;;service:;;name:[[:space:]]*nginx;;state:[[:space:]]*restarted
task13_nginx_tasks_main.png|none|install[[:space:]]+nginx;;yum:;;install[[:space:]]+openssl;;start[[:space:]]+and[[:space:]]+enable[[:space:]]+nginx;;notify:[[:space:]]*restart[[:space:]]+nginx
task13_my_playbook_nginx_only.png|none|deploy[[:space:]]+nginx[[:space:]]+web[[:space:]]+stack;;hosts:[[:space:]]*nginx;;roles:;;-[[:space:]]*nginx
task13_ansible_play_nginx_only.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+inventory/hosts[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0
task13_nginx_browser_roles.png|none|http://[0-9]{1,3}([.][0-9]{1,3}){3};;(welcome[[:space:]]+to[[:space:]]+nginx|nginx)
task13_ssl_defaults_main.png|none|imdsv2_token_ttl:[[:space:]]*"?3600;;ssl_days_valid:[[:space:]]*365
task13_ssl_tasks_main.png|none|create[[:space:]]+ssl[[:space:]]+private[[:space:]]+directory;;get[[:space:]]+imdsv2[[:space:]]+token;;get[[:space:]]+public[[:space:]]+ip;;openssl[[:space:]]+req;;selfsigned[.]key;;selfsigned[.]crt
task13_webapp_defaults_main.png|none|nginx_user:[[:space:]]*nginx;;nginx_worker_processes:[[:space:]]*auto;;nginx_worker_connections:[[:space:]]*1024;;web_root:;;web_index_file:[[:space:]]*index[.]php
task13_webapp_files_index_php.png|none|getimds(v2)?token;;getmetadata;;instance-id;;local-ipv4;;public-ipv4;;frontend[[:space:]]+web[[:space:]]+server;;terraform[[:space:]]+[+]?[[:space:]]*ansible
task13_webapp_handlers_main.png|none|restart[[:space:]]+nginx;;restart[[:space:]]+php-fpm;;service:;;state:[[:space:]]*restarted
task13_webapp_templates_nginx_conf.png|none|nginx_user;;nginx_worker_processes;;listen[[:space:]]+443[[:space:]]+ssl;;server_public_ip;;selfsigned[.]crt;;fastcgi_pass;;php-fpm;;return[[:space:]]+301[[:space:]]+https
task13_webapp_tasks_main.png|none|install[[:space:]]+php[[:space:]]+packages;;copy[[:space:]]+php[[:space:]]+website;;deploy[[:space:]]+nginx[[:space:]]+config;;php-fpm;;notify:[[:space:]]+restart
task13_my_playbook_roles.png|none|deploy[[:space:]]+nginx[[:space:]]+web[[:space:]]+stack;;hosts:[[:space:]]*nginx;;roles:;;-[[:space:]]*nginx;;-[[:space:]]*ssl;;-[[:space:]]*webapp
task13_ansible_play_roles.png|codespace|ansible-playbook[[:space:]]+-i[[:space:]]+inventory/hosts[[:space:]]+my-playbook[.]yaml;;play[[:space:]]+recap;;failed=0;;(nginx|ssl|webapp)
task13_php_https_browser_roles.png|none|https://[0-9]{1,3}([.][0-9]{1,3}){3};;nginx[[:space:]]+front[[:space:]]+end[[:space:]]+web[[:space:]]+server;;hostname;;instance[[:space:]]+id;;managed[[:space:]]+by;;terraform[[:space:]]+[+]?[[:space:]]*ansible
cleanup_terraform_destroy.png|codespace|terraform[[:space:]]+destroy;;destroy[[:space:]]+complete;;destroyed
cleanup_tfstate.png|codespace|cat[[:space:]]+terraform[.]tfstate;;"resources"[[:space:]]*:[[:space:]]*\[;;"outputs"[[:space:]]*:[[:space:]]*\{
cleanup_aws_console.png|none|(ec2|instances);;(0[[:space:]]+running|no[[:space:]]+running[[:space:]]+instances|0[[:space:]]+instances|no[[:space:]]+instances)
EOF

required=${#criteria[@]}

# OCR screenshots concurrently. By default, use the runner's available logical
# CPUs. OCR_JOBS may request fewer workers but cannot exceed available CPUs or 8.
ocr_dir="$(mktemp -d "/tmp/lab14-ocr-${normalized_username}.XXXXXX")"
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
  duplicate_index="/tmp/lab14-duplicate-images-${duplicate_key}.tsv"

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

  # Reject private keys, AWS credentials, GitHub tokens, and hard-coded Gitea
  # database passwords. Certificate/private-key evidence must show safe file
  # metadata or key validation output rather than the private key body.
  if grep -Eqi -- '(begin.*private[[:space:]]+key|(akia|asia)[0-9a-z]{16}|ghp_[0-9a-z]{30,}|github_pat_[0-9a-z_]{30,}|aws_secret_access_key[[:space:]]*=[[:space:]]*[0-9a-z/+=]{20,}|(db_passwd|postgres_password)[[:space:]]*=[[:space:]]*[\"]?[0-9a-z!@#%&*._+-]{4,})' <<<"$ocr_text"; then
    feedback+=("$filename: exposed credential, password, token, or private-key material is visible (0)")
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

summary="Passed $passed/$required Lab 14 required screenshot checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
