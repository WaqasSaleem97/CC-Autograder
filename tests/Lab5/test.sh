#!/usr/bin/env bash
set -u

# Grade the core Lab 05 requirements from Tasks 1 through 12.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab5/test.sh \
#     work/submissions/Student/CC/Labs/Lab05 \
#     10
#
# Manual example:
#   bash tests/Lab5/test.sh /path/to/CC/Labs/Lab05 10 waqassaleem97

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

for command in tesseract python3 git node sha256sum realpath xargs find grep sed awk tr cut; do
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
grader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! -d "$screenshots_dir" ]]; then
  json_error "Required directory is missing: Labs/Lab05/screenshots"
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
# filename or comma-separated alternatives|identity|required OCR expressions
#
# Identity flags:
#   none   - no terminal identity requirement
#   prompt - a terminal prompt containing <GitHub username>@ubuntu must appear
#
# Expressions separated by ;; are all required. An expression beginning with !
# is forbidden and must be absent.
readarray -t criteria <<'EOF'
task1_java_suggestion.png|prompt|java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task1_java_install.png|none|apt[[:space:]]+install;;(default-jre|openjdk|java);;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers|already[[:space:]]+the[[:space:]]+newest)
task1_java_version.png|prompt|java[[:space:]]+--version;;(openjdk|java);;[0-9]+[.][0-9]+
task1_java_remove.png|none|apt[[:space:]]+remove;;(default-jre|openjdk|java);;(removing|will[[:space:]]+be[[:space:]]+removed|processing[[:space:]]+triggers)
task1_java_not_found.png|prompt|java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task1_hash_clear.png|prompt|hash[[:space:]]+-r;;java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task2_aptget_install.png|none|apt[[:space:]-]*get;;install;;(default-jre|openjdk|java);;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers|already[[:space:]]+the[[:space:]]+newest)
task2_java_version_after_aptget.png|prompt|java[[:space:]]+--version;;(openjdk|java);;[0-9]+[.][0-9]+
task2_aptget_remove.png|none|apt[[:space:]-]*get;;remove;;(default-jre|openjdk|java);;(removing|will[[:space:]]+be[[:space:]]+removed|processing[[:space:]]+triggers)
task2_hash_after_remove.png|prompt|hash[[:space:]]+-r;;java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task3_apt_update.png|none|apt[[:space:]]+update;;(reading[[:space:]]+package[[:space:]]+lists|hit:|get:|all[[:space:]]+packages[[:space:]]+are[[:space:]]+up[[:space:]]+to[[:space:]]+date)
task3_apt_upgrade.png|none|apt[[:space:]]+upgrade;;(upgraded|newly[[:space:]]+installed|not[[:space:]]+upgraded|calculating[[:space:]]+upgrade)
task3_explanation.png|none|apt[[:space:]]+update;;(package[[:space:]]+index|package[[:space:]]+list|metadata|refresh);;apt[[:space:]]+upgrade;;(installed[[:space:]]+packages|newer[[:space:]]+versions|available[[:space:]]+upgrades|updates)
task4_snap_install.png|none|snap[[:space:]]+install;;classic;;code;;(installed|visual[[:space:]]+studio[[:space:]]+code)
task4_snap_list.png|prompt|snap[[:space:]]+list[[:space:]]+code;;(code|vscode);;(version|publisher|rev|tracking)
task4_code_version_or_info.png|prompt|code[[:space:]]+--version;;[0-9]+[.][0-9]+
task4_snap_bin_location.png|prompt|ls[[:space:]]+-l;;/snap/bin/code;;code
task5_update.png|none|apt[[:space:]]+update;;apt[[:space:]]+upgrade;;(upgraded|package[[:space:]]+lists|up[[:space:]]+to[[:space:]]+date)
task5_xfce_install.png|none|apt[[:space:]]+install;;xfce4;;xfce4-goodies;;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers)
task5_xrdp_enable.png|prompt|xrdp;;(apt[[:space:]]+install|systemctl[[:space:]]+enable|adduser);;(enable|ssl-cert|installed|created[[:space:]]+symlink)
task5_xrdp_status.png|prompt|systemctl[[:space:]]+status[[:space:]]+xrdp;;active[[:space:]]*\(running\)
task5_xsession.png|prompt|xfce4-session;;[.]xsession
task5_rdp_connect.png|none|(xfce|xrdp|remote[[:space:]]+desktop|applications);;(desktop|session|terminal|ubuntu)
task5_vscode_launch.png|none|(visual[[:space:]]+studio[[:space:]]+code|welcome);;(file|edit|selection);;(view|terminal|extensions)
task6_lightdm_install.png|none|apt[[:space:]]+install;;lightdm;;lightdm-gtk-greeter;;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers|already[[:space:]]+the[[:space:]]+newest)
task6_lightdm_config.png|prompt|lightdm[.]conf[.]d;;greeter-session;;lightdm-gtk-greeter;;user-session;;xfce
task6_lightdm_cleanup.png|prompt|rm;;[.]Xauthority;;cache/sessions
task6_lightdm_restart.png|prompt|systemctl[[:space:]]+(restart|status)[[:space:]]+lightdm;;active[[:space:]]*\(running\)
task6_gui_enable_boot.png|prompt|systemctl[[:space:]]+enable[[:space:]]+lightdm;;set-default[[:space:]]+graphical[.]target;;graphical[.]target
task6_after_reboot_gui.png|none|(lightdm|ubuntu|xfce);;(login|password|session)
task6_gui_disable_boot.png|prompt|set-default[[:space:]]+multi-user[.]target;;systemctl[[:space:]]+disable[[:space:]]+lightdm;;multi-user[.]target
task6_after_reboot_cli.png|none|(ubuntu|linux);;(login:|tty[0-9]+|last[[:space:]]+login|welcome)
task6_gui_start.png|prompt|systemctl[[:space:]]+(start|is-active)[[:space:]]+lightdm;;^[[:space:]]*active[[:space:]]*$
task6_vscode_launch.png|none|(visual[[:space:]]+studio[[:space:]]+code|welcome);;(file|edit|selection);;(view|terminal|extensions)
task6_gui_stop.png|prompt|systemctl[[:space:]]+(stop|is-active)[[:space:]]+lightdm;;inactive
task7_install_chrome_error.png|prompt|apt[[:space:]]+install[[:space:]]+google-chrome-stable;;(unable[[:space:]]+to[[:space:]]+locate[[:space:]]+package|has[[:space:]]+no[[:space:]]+installation[[:space:]]+candidate|couldn.t[[:space:]]+find)
task7_ls_sources_list_d.png|prompt|ls[[:space:]]+-la[[:space:]]+/etc/apt/sources[.]list[.]d;;(ubuntu[.]sources|sources|total)
task7_prerequisites.png|none|apt[[:space:]]+install;;curl;;gpg
task7_add_key.png|prompt|curl;;linux_signing_key[.]pub;;gpg;;dearmor;;google-chrome[.]gpg
task7_create_google_chrome_list.png|prompt|https://dl[.]google[.]com/linux/chrome/deb/;;google-chrome[.]list;;signed-by;;stable;;main
task7_verify_source.png|prompt|cat[[:space:]]+/etc/apt/sources[.]list[.]d/google-chrome[.]list;;https://dl[.]google[.]com/linux/chrome/deb/;;signed-by;;stable;;main
task7_apt_update.png|none|apt[[:space:]]+update;;(dl[.]google[.]com|google[[:space:]]+chrome);;(package[[:space:]]+lists|hit:|get:)
task7_install_chrome.png|none|apt[[:space:]]+install[[:space:]]+google-chrome-stable;;(setting[[:space:]]+up[[:space:]]+google-chrome|newly[[:space:]]+installed|google-chrome-stable)
task7_chrome_version.png|prompt|google-chrome[[:space:]]+--version;;google[[:space:]]+chrome;;[0-9]+[.][0-9]+
task8_add_ppa_audacity.png|none|add-apt-repository;;ppa:ubuntuhandbook1/audacity;;(repository|adding|PPA)
task8_apt_update_audacity.png|none|apt[[:space:]]+update;;(audacity|ubuntuhandbook1);;(package[[:space:]]+lists|hit:|get:)
task8_install_audacity.png|none|apt[[:space:]]+install[[:space:]]+audacity;;(setting[[:space:]]+up|newly[[:space:]]+installed|audacity)
task8_audacity_launch.png,task8_audacity_version.png|none|audacity;;(version|file|edit|transport|tracks|audio)
task8_add_ppa_obs.png|none|add-apt-repository;;ppa:obsproject/obs-studio;;(repository|adding|PPA)
task8_apt_update_obs.png|none|apt[[:space:]]+update;;(obsproject|obs-studio);;(package[[:space:]]+lists|hit:|get:)
task8_install_obs.png|none|apt[[:space:]]+install[[:space:]]+obs-studio;;(setting[[:space:]]+up|newly[[:space:]]+installed|obs-studio)
task8_obs_launch.png,task8_obs_version.png|none|(OBS[[:space:]]+Studio|obs);;(version|scenes|sources|audio[[:space:]]+mixer|controls)
task9_vim_check.png|none|(VIM|Vi[[:space:]]+IMproved|command[[:space:]]+not[[:space:]]+found);;(version|help|install|~)
task9_mkdir_cd.png|prompt|mkdir;;Lab5;;(cd|/Lab5);;pwd
task9_vim_edit.png|none|apiVersion:[[:space:]]+v1;;kind:[[:space:]]+Pod;;name:[[:space:]]+nginx-pod;;image:[[:space:]]+nginx:1[.]19;;containerPort:[[:space:]]+80
task9_k8s_saved.png|prompt|ls[[:space:]]+-l;;k8s-sample[.]yaml;;apiVersion:[[:space:]]+v1;;kind:[[:space:]]+Pod
task10_verify_annotation.png|prompt|cat[[:space:]]+k8s-sample[.]yaml;;annotations:;;lab:[[:space:]]+lesson11;;nginx-pod
task10_verify_entering_temp_data.png|none|temp:[[:space:]]+do-not-keep;;k8s-sample[.]yaml
task10_verify_no_temp_comment.png|prompt|cat[[:space:]]+k8s-sample[.]yaml;;annotations:;;lab:[[:space:]]+lesson11;;nginx-pod;;!temp:[[:space:]]+do-not-keep
task11_dd_delete_and_undo.png|none|image:[[:space:]]+nginx:1[.]19;;containerPort:[[:space:]]+80;;restartPolicy:[[:space:]]+Always
task11_delete3_and_undo.png|none|image:[[:space:]]+nginx:1[.]19;;containerPort:[[:space:]]+80;;restartPolicy:[[:space:]]+Always
task11_line1.png|none|apiVersion:[[:space:]]+v1
task11_navigation.png|none|containerPort:[[:space:]]+80
task12_search_nginx.png|none|nginx;;(nginx-pod|name:[[:space:]]+nginx|image:[[:space:]]+nginx|k8s-sample[.]yaml)
task12_n_and_N_navigation.png|none|(nginx-pod|name:[[:space:]]+nginx);;image:[[:space:]]+nginx
task12_added_occurrences.png|none|nginx;;(comment|#|metadata|image)
task12_cycle_matches.png|none|nginx;;(nginx-pod|image:[[:space:]]+nginx|k8s-sample[.]yaml)
task12_substitute_result.png|none|webapp;;!nginx
task12_undo_and_quit.png|none|nginx;;!webapp
EOF

required_screenshots=${#criteria[@]}
if (( required_screenshots != 69 )); then
  json_error "Trusted Lab 5 grader configuration must contain exactly 69 core screenshot checks."
fi

# Conditional evidence is reported but never changes the score.
optional_files=(
  task9_vim_install.png
)

# Resolve every accepted filename by stem. Case and image extensions, including
# repeated extensions such as .png.png, do not affect the match.
expected_screenshots=()
for rule in "${criteria[@]}"; do
  filename_spec="${rule%%|*}"
  IFS=',' read -r -a candidates <<<"$filename_spec"
  expected_screenshots+=("${candidates[@]}")
done

declare -A resolved_screenshots
while IFS=$'\t' read -r expected actual; do
  resolved_screenshots["$expected"]="$actual"
done < <(
  python3 "$grader_root/scripts/resolve_screenshots.py" \
    "$screenshots_dir" "${expected_screenshots[@]}"
)

resolve_filename() {
  local filename_spec="$1"
  local candidate
  local actual
  local ambiguous=false
  local -a candidates=()
  IFS=',' read -r -a candidates <<<"$filename_spec"

  for candidate in "${candidates[@]}"; do
    actual="${resolved_screenshots[$candidate]:-}"
    if [[ "$actual" == "__AMBIGUOUS__" ]]; then
      ambiguous=true
    elif [[ -n "$actual" && -f "$actual" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if [[ "$ambiguous" == true ]]; then
    printf '%s\n' "__AMBIGUOUS__"
    return 0
  fi
  return 1
}

# OCR all available required and alternative screenshots concurrently.
ocr_dir="$(mktemp -d "/tmp/lab5-ocr-${normalized_username}.XXXXXX")"
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

for filename in "${expected_screenshots[@]}"; do
  image="${resolved_screenshots[$filename]:-}"
  [[ -f "$image" ]] && printf '%s\0%s\0' "$filename" "$image"
done |
  xargs -0 -r -P "$ocr_jobs" -n 2 \
    bash -c '
      ocr_dir="$1"
      helper="$2"
      filename="$3"
      source_image="$4"
      python3 "$helper" "$source_image" "$ocr_dir/${filename%.*}.txt"
    ' _ "$ocr_dir" "$grader_root/scripts/ocr_screenshot.py"

# Build one exact-duplicate index for screenshots with the same logical task
# across all students selected in the workflow run.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab5-duplicate-images-${duplicate_key}.tsv"

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
image_extensions = (".jpeg", ".jpg", ".png", ".webp", ".bmp", ".tiff", ".tif", ".gif")
aliases = {
    "task8_audacity_version": "task8_audacity_launch",
    "task8_obs_version": "task8_obs_launch",
}

def filename_key(name):
    value = name.casefold().rstrip(".")
    while True:
        for extension in image_extensions:
            if value.endswith(extension):
                value = value[:-len(extension)].rstrip(".")
                break
        else:
            return aliases.get(value, value)

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file():
            groups[filename_key(image.name)].append(image.resolve())

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
  filename_spec="${rule%%|*}"
  primary_filename="${filename_spec%%,*}"
  remainder="${rule#*|}"
  identity_flag="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  actual_filename="$(resolve_filename "$filename_spec" || true)"

  if [[ "$actual_filename" == "__AMBIGUOUS__" ]]; then
    feedback+=("$primary_filename: multiple files match when case and extensions are ignored (0)")
    continue
  fi

  if [[ -z "$actual_filename" ]]; then
    if [[ "$filename_spec" == *,* ]]; then
      feedback+=("$primary_filename: missing; accepted alternatives are $filename_spec (0)")
    else
      feedback+=("$primary_filename: missing (0)")
    fi
    continue
  fi

  image="${resolved_screenshots[$actual_filename]}"

  if ! python3 - "$image" <<'PY' >/dev/null 2>&1
from PIL import Image
import sys

with Image.open(sys.argv[1]) as image:
    image.verify()
PY
  then
    feedback+=("$actual_filename: invalid or corrupt image (0)")
    continue
  fi

  canonical_image="$(realpath "$image")"
  if [[ -n "$duplicate_index" && -s "$duplicate_index" ]]; then
    duplicate_reason="$(awk -F '\t' -v path="$canonical_image" '$1 == path {print $2; exit}' "$duplicate_index")"
    if [[ -n "$duplicate_reason" ]]; then
      feedback+=("$actual_filename: $duplicate_reason (0)")
      continue
    fi
  fi

  ocr_file="$ocr_dir/${actual_filename%.*}.txt"
  ocr_text=""
  if [[ -f "$ocr_file" ]]; then
    ocr_text="$(tr '[:upper:]' '[:lower:]' < "$ocr_file")"
  fi

  if [[ -z "${ocr_text//[[:space:]]/}" ]]; then
    feedback+=("$actual_filename: unreadable OCR (0)")
    continue
  fi

  if [[ "$identity_flag" == "prompt" ]]; then
    if ! python3 "$grader_root/scripts/ocr_evidence.py" \
      prompt "$normalized_username" "$ocr_file"; then
      feedback+=("$actual_filename: ${github_username}@ubuntu terminal prompt was not clearly detected (0)")
      continue
    fi
  fi

  evidence_ok=true
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    if [[ "$evidence_pattern" == \!* ]]; then
      forbidden_pattern="${evidence_pattern#!}"
      if grep -Eqi -- "$forbidden_pattern" <<<"$ocr_text"; then
        evidence_ok=false
        break
      fi
    elif ! grep -Eqi -- "$evidence_pattern" <<<"$ocr_text"; then
      evidence_ok=false
      break
    fi
  done < <(printf '%s' "$evidence_groups" | sed 's/;;/\n/g')

  if [[ "$evidence_ok" != true ]]; then
    feedback+=("$actual_filename: required task evidence was not detected (0)")
    continue
  fi

  passed=$((passed + 1))
  if [[ "$actual_filename" != "$primary_filename" ]]; then
    feedback+=("$primary_filename: passed using accepted alternative $actual_filename")
  else
    feedback+=("$primary_filename: passed")
  fi
done

# Validate the final manifest required in Labs/Lab05/workspace.
manifest="$submission_dir/workspace/k8s-sample.yaml"
manifest_problem=""
if manifest_problem="$(python3 - "$manifest" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.is_file() or path.stat().st_size == 0:
    print("workspace/k8s-sample.yaml is missing or empty")
    raise SystemExit(1)

text = path.read_text(encoding="utf-8", errors="replace")
if "\t" in text:
    print("the manifest uses tab indentation, which is invalid YAML")
    raise SystemExit(1)
if re.search(r"\bwebapp\b|temp:\s*do-not-keep", text, flags=re.IGNORECASE):
    print("the final manifest still contains temporary or substituted text")
    raise SystemExit(1)

records = []
for number, line in enumerate(text.splitlines(), 1):
    stripped = line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    records.append((number, len(line) - len(line.lstrip(" ")), stripped))

def locate(pattern, start=0):
    expression = re.compile(pattern, flags=re.IGNORECASE)
    for index in range(start, len(records)):
        if expression.fullmatch(records[index][2]):
            return index
    return -1

api = locate(r"apiVersion:\s*v1")
kind = locate(r"kind:\s*Pod", api + 1)
metadata = locate(r"metadata:", kind + 1)
pod_name = locate(r"name:\s*nginx-pod", metadata + 1)
annotations = locate(r"annotations:", pod_name + 1)
lab = locate(r"lab:\s*lesson11", annotations + 1)
spec = locate(r"spec:", lab + 1)
containers = locate(r"containers:", spec + 1)
container_name = locate(r"-\s*name:\s*nginx", containers + 1)
image = locate(r"image:\s*nginx:1[.]19", container_name + 1)
ports = locate(r"ports:", image + 1)
container_port = locate(r"-\s*containerPort:\s*80", ports + 1)
restart = locate(r"restartPolicy:\s*Always", container_port + 1)

positions = [
    api, kind, metadata, pod_name, annotations, lab, spec, containers,
    container_name, image, ports, container_port, restart,
]
if any(position < 0 for position in positions):
    print("the manifest is missing one or more required Kubernetes fields")
    raise SystemExit(1)

if sum(1 for _line, indent, value in records if indent == 0 and value.lower() == "spec:") != 1:
    print("the manifest must contain exactly one top-level spec section")
    raise SystemExit(1)

indent = lambda index: records[index][1]
if not (
    indent(metadata) == 0
    and indent(pod_name) > indent(metadata)
    and indent(annotations) == indent(pod_name)
    and indent(lab) > indent(annotations)
    and indent(spec) == 0
    and indent(containers) > indent(spec)
    and indent(container_name) > indent(containers)
    and indent(image) > indent(container_name)
    and indent(ports) == indent(image)
    and indent(container_port) > indent(ports)
    and indent(restart) == indent(containers)
):
    print("the required Kubernetes fields are not nested correctly")
    raise SystemExit(1)
PY
)"; then
  passed=$((passed + 1))
  feedback+=("workspace/k8s-sample.yaml: passed")
else
  feedback+=("workspace/k8s-sample.yaml: $manifest_problem (0)")
fi

# Require the exact, non-empty PDF specified by the Lab 05 submission section.
solution_pdf="$submission_dir/Lab5_Solution.pdf"
pdf_problem=""
if [[ ! -s "$solution_pdf" ]]; then
  pdf_problem="Lab5_Solution.pdf is missing or empty"
elif ! python3 - "$solution_pdf" <<'PY' >/dev/null 2>&1
import sys
from pathlib import Path

with Path(sys.argv[1]).open("rb") as source:
    assert source.read(5) == b"%PDF-"
PY
then
  pdf_problem="Lab5_Solution.pdf is not a valid PDF file"
fi

if [[ -z "$pdf_problem" ]]; then
  passed=$((passed + 1))
  feedback+=("Lab5_Solution.pdf: passed")
else
  feedback+=("Lab5_Solution.pdf: $pdf_problem (0)")
fi

optional_present=0
for optional_file in "${optional_files[@]}"; do
  canonical_optional="$(printf '%s' "$optional_file" | tr '[:upper:]' '[:lower:]')"
  [[ -f "$screenshots_dir/$canonical_optional" ]] && optional_present=$((optional_present + 1))
done

required=$((required_screenshots + 2))
if (( required != 71 )); then
  json_error "Trusted Lab 5 grader configuration must contain exactly 71 scored checks."
fi

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

summary="Passed $passed/$required Lab 5 core checks. Conditional Vim-install evidence present: $optional_present/${#optional_files[@]} (not scored). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
