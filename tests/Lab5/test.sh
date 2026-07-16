#!/usr/bin/env bash
set -u

# Grade Lab 5 screenshot evidence.
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
escaped_username="$(printf '%s' "$normalized_username" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"

# Format:
# filename or comma-separated alternative filenames|identity|required OCR
# expressions separated by ;;
#
# Identity flags:
#   none   - no username requirement
#   prompt - a terminal prompt containing <GitHub username>@<host> must appear
#
# An OCR expression beginning with ! is forbidden evidence and must be absent.
readarray -t criteria <<'EOF'
task1_java_suggestion.png|prompt|java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task1_java_install.png|none|apt[[:space:]]+install;;(default-jre|openjdk|java);;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers)
task1_java_version.png|prompt|java[[:space:]]+--version;;(openjdk|java);;[0-9]+[.][0-9]+
task1_java_remove.png|none|apt[[:space:]]+remove;;(default-jre|openjdk|java);;(removing|will[[:space:]]+be[[:space:]]+removed|processing[[:space:]]+triggers)
task1_java_not_found.png|prompt|java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task1_hash_clear.png|prompt|hash[[:space:]]+-r;;java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task2_aptget_install.png|none|apt-get;;(update|install);;(default-jre|openjdk|java);;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers)
task2_java_version_after_aptget.png|prompt|java[[:space:]]+--version;;(openjdk|java);;[0-9]+[.][0-9]+
task2_aptget_remove.png|none|apt-get[[:space:]]+remove;;(default-jre|openjdk|java);;(removing|will[[:space:]]+be[[:space:]]+removed|processing[[:space:]]+triggers)
task2_hash_after_remove.png|prompt|hash[[:space:]]+-r;;java;;(command[[:space:]]+not[[:space:]]+found|can[[:space:]]+be[[:space:]]+found|sudo[[:space:]]+apt[[:space:]]+install)
task3_apt_update.png|none|apt[[:space:]]+update;;(reading[[:space:]]+package[[:space:]]+lists|hit:|get:|all[[:space:]]+packages[[:space:]]+are[[:space:]]+up[[:space:]]+to[[:space:]]+date)
task3_apt_upgrade.png|none|apt[[:space:]]+upgrade;;(upgraded|newly[[:space:]]+installed|not[[:space:]]+upgraded|calculating[[:space:]]+upgrade)
task3_explanation.png|none|apt[[:space:]]+update;;(package[[:space:]]+index|package[[:space:]]+list|refresh);;apt[[:space:]]+upgrade;;(installed[[:space:]]+packages|newer[[:space:]]+versions|updates)
task4_snap_install.png|none|snap[[:space:]]+install;;classic;;code;;(installed|visual[[:space:]]+studio[[:space:]]+code)
task4_snap_list.png|prompt|snap[[:space:]]+list[[:space:]]+code;;(code|vscode);;(version|publisher|rev|tracking)
task4_code_version_or_info.png|prompt|(code[[:space:]]+--version|snap[[:space:]]+info[[:space:]]+code);;[0-9]+[.][0-9]+
task4_snap_bin_location.png|prompt|/snap/bin;;grep[[:space:]]+code;;code
task5_update.png|none|apt[[:space:]]+update;;apt[[:space:]]+upgrade;;(upgraded|package[[:space:]]+lists|up[[:space:]]+to[[:space:]]+date)
task5_xfce_install.png|none|apt[[:space:]]+install;;xfce4;;xfce4-goodies;;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers)
task5_xrdp_enable.png|prompt|(apt[[:space:]]+install[[:space:]]+xrdp|systemctl[[:space:]]+enable[[:space:]]+--now[[:space:]]+xrdp);;xrdp
task5_xrdp_status.png|prompt|systemctl[[:space:]]+status[[:space:]]+xrdp;;active[[:space:]]*\(running\)
task5_xsession.png|prompt|xfce4-session;;[.]xsession
task5_rdp_connect.png|none|(xfce|xrdp|remote[[:space:]]+desktop|applications);;(desktop|session|terminal|ubuntu)
task5_vscode_launch.png|none|(visual[[:space:]]+studio[[:space:]]+code|welcome);;(file|edit|selection);;(view|terminal|extensions)
task6_lightdm_install.png|none|apt[[:space:]]+install;;lightdm;;lightdm-gtk-greeter;;(setting[[:space:]]+up|newly[[:space:]]+installed|processing[[:space:]]+triggers)
task6_lightdm_config.png|prompt|lightdm[.]conf[.]d;;greeter-session;;lightdm-gtk-greeter;;user-session;;xfce
task6_lightdm_cleanup.png|prompt|[.]Xauthority;;cache/sessions;;chown;;/home/
task6_lightdm_restart.png|prompt|systemctl[[:space:]]+restart[[:space:]]+lightdm
task6_gui_enable_boot.png|prompt|systemctl[[:space:]]+enable[[:space:]]+lightdm;;set-default[[:space:]]+graphical[.]target
task6_after_reboot_gui.png|none|(lightdm|ubuntu|xfce);;(login|password|session)
task6_gui_disable_boot.png|prompt|set-default[[:space:]]+multi-user[.]target;;systemctl[[:space:]]+disable[[:space:]]+lightdm
task6_after_reboot_cli.png|none|(ubuntu|linux);;(login:|tty[0-9]+|last[[:space:]]+login|welcome)
task6_gui_start.png|prompt|systemctl[[:space:]]+start[[:space:]]+lightdm
task6_gui_stop.png|prompt|systemctl[[:space:]]+stop[[:space:]]+lightdm
task6_gui_start_command.png|prompt|systemctl[[:space:]]+start[[:space:]]+lightdm
task6_vscode_launch.png|none|(visual[[:space:]]+studio[[:space:]]+code|welcome);;(file|edit|selection);;(view|terminal|extensions)
task7_install_chrome_error.png|prompt|apt[[:space:]]+install[[:space:]]+google-chrome-stable;;(unable[[:space:]]+to[[:space:]]+locate[[:space:]]+package|has[[:space:]]+no[[:space:]]+installation[[:space:]]+candidate|couldn.t[[:space:]]+find)
task7_ls_etc_apt.png|prompt|ls[[:space:]]+-la[[:space:]]+/etc/apt;;(sources[.]list|sources[.]list[.]d);;(keyrings|trusted[.]gpg)
task7_cat_sources_list.png|prompt|cat[[:space:]]+/etc/apt/sources[.]list;;(deb|ubuntu|source|moved)
task7_ls_sources_list_d.png|prompt|ls[[:space:]]+-la[[:space:]]+/etc/apt/sources[.]list[.]d;;(ubuntu[.]sources|sources|total)
task7_cat_ubuntu_sources.png|prompt|cat[[:space:]]+/etc/apt/sources[.]list[.]d/ubuntu[.]sources;;(Types:|URIs:|Suites:|Components:|no[[:space:]]+such[[:space:]]+file|does[[:space:]]+not[[:space:]]+exist)
task7_edit_ubuntu_sources.png,task7_create_google_chrome_list.png|none|(dl[.]google[.]com/linux/chrome/deb|google-chrome[.]list);;stable;;main;;google[.]gpg
task7_add_key.png,task7_add_key_alt.png|prompt|curl;;linux_signing_key[.]pub;;gpg;;dearmor;;google[.]gpg
task7_apt_update.png,task7_apt_update_alt.png|none|apt[[:space:]]+update;;(dl[.]google[.]com|google[[:space:]]+chrome);;(package[[:space:]]+lists|hit:|get:)
task7_install_chrome.png,task7_install_chrome_alt.png|none|apt[[:space:]]+install[[:space:]]+google-chrome-stable;;(setting[[:space:]]+up[[:space:]]+google-chrome|newly[[:space:]]+installed|google-chrome-stable)
task8_add_ppa_audacity.png|none|add-apt-repository;;ppa:ubuntuhandbook1/audacity;;(repository|adding|PPA)
task8_apt_update_audacity.png|none|apt[[:space:]]+update;;(audacity|ubuntuhandbook1);;(package[[:space:]]+lists|hit:|get:)
task8_install_audacity.png|none|apt[[:space:]]+install[[:space:]]+audacity;;(setting[[:space:]]+up|newly[[:space:]]+installed|audacity)
task8_audacity_launch.png,task8_audacity_version.png|none|audacity;;(version|file|edit|transport|tracks|audio)
task8_add_ppa_obs.png|none|add-apt-repository;;ppa:obsproject/obs-studio;;(repository|adding|PPA)
task8_apt_update_obs.png|none|apt[[:space:]]+update;;(obsproject|obs-studio);;(package[[:space:]]+lists|hit:|get:)
task8_install_obs.png|none|apt[[:space:]]+install[[:space:]]+obs-studio;;(setting[[:space:]]+up|newly[[:space:]]+installed|obs-studio)
task8_obs_launch.png,task8_obs_version.png|none|(OBS[[:space:]]+Studio|obs);;(version|scenes|sources|audio[[:space:]]+mixer|controls)
task9_vim_check.png|none|(VIM|Vi[[:space:]]+IMproved|command[[:space:]]+not[[:space:]]+found);;(version|help|install|~)
task9_mkdir_cd.png|prompt|mkdir;;Lab5;;(cd|/Lab5)
task9_vim_edit.png|none|apiVersion:[[:space:]]+v1;;kind:[[:space:]]+Pod;;name:[[:space:]]+nginx-pod;;image:[[:space:]]+nginx:1[.]19;;containerPort:[[:space:]]+80
task9_k8s_saved.png|prompt|ls[[:space:]]+-la;;k8s-sample[.]yaml
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
exam_evaluation_docker_desktop.png|none|docker[[:space:]]+desktop;;(engine[[:space:]]+running|running|containers|images|dashboard)
EOF

required_screenshots=${#criteria[@]}

# These are conditional, cleanup-only, redundant verification, or checklist
# typo screenshots. They are reported but are not part of the score.
optional_files=(
  task7_alternate_remove.png
  task7_alternate_edit.png
  task7_remove_key.png
  task7_list_sources_after_create.png
  task9_vim_install.png
  task5_after_reboot_gui.png
  task5_after_reboot_cli.png
)

# Return the first available filename from a comma-separated alternative set.
resolve_filename() {
  local filename_spec="$1"
  local candidate
  local -a candidates=()
  IFS=',' read -r -a candidates <<<"$filename_spec"
  for candidate in "${candidates[@]}"; do
    if [[ -f "$screenshots_dir/$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# OCR every available required/alternative screenshot concurrently.
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

printf '%s\n' "${criteria[@]}" |
  cut -d'|' -f1 |
  while IFS= read -r filename_spec; do
    resolve_filename "$filename_spec" || true
  done |
  sort -u |
  xargs -r -P "$ocr_jobs" -I '{}' \
    bash -c '
      source_image="$1/$2"
      output_base="$3/${2%.*}"
      tesseract "$source_image" "$output_base" --psm 11 2>/dev/null || true
    ' _ "$screenshots_dir" '{}' "$ocr_dir"

# Build an exact-duplicate index for the same logical task across all students
# selected in this workflow. Alternative filenames are normalized to their
# canonical task filename. Both matching students receive zero for that task.
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

canonical_names = {
    "task7_create_google_chrome_list.png": "task7_edit_ubuntu_sources.png",
    "task7_add_key_alt.png": "task7_add_key.png",
    "task7_apt_update_alt.png": "task7_apt_update.png",
    "task7_install_chrome_alt.png": "task7_install_chrome.png",
    "task8_audacity_version.png": "task8_audacity_launch.png",
    "task8_obs_version.png": "task8_obs_launch.png",
}

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file() and image.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            logical_name = canonical_names.get(image.name.lower(), image.name.lower())
            groups[logical_name].append(image.resolve())

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

  if [[ -z "$actual_filename" ]]; then
    if [[ "$filename_spec" == *,* ]]; then
      feedback+=("$primary_filename: missing; accepted alternatives are $filename_spec (0)")
    else
      feedback+=("$primary_filename: missing (0)")
    fi
    continue
  fi

  image="$screenshots_dir/$actual_filename"

  # Verify that Pillow can decode the image. No minimum-dimension rule is used.
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
    if ! grep -Eqi "${escaped_username}[[:space:]]*@[[:space:]]*[[:alnum:]_.-]+" <<<"$ocr_text"; then
      feedback+=("$actual_filename: ${github_username}@host terminal prompt was not clearly detected (0)")
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

optional_present=0
for optional_file in "${optional_files[@]}"; do
  [[ -f "$screenshots_dir/$optional_file" ]] && optional_present=$((optional_present + 1))
done

# The submission section labels workspace and report files as optional, so
# neither is included in the score. Report their presence for instructor use.
word_report_present=false
alternate_report_present=false
if find "$submission_dir" -maxdepth 1 -type f \
  \( -iname '*.doc' -o -iname '*.docx' \) -size +0c -print -quit |
  grep -q .; then
  word_report_present=true
fi
if find "$submission_dir" -maxdepth 1 -type f \
  \( -iname '*.pdf' -o -iname '*.md' \) \
  ! -iname 'README.md' -size +0c -print -quit |
  grep -q .; then
  alternate_report_present=true
fi

required=$required_screenshots

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

summary="Passed $passed/$required Lab 5 required checks. Optional screenshots present: $optional_present/${#optional_files[@]} (not scored). Optional reports: Word=$word_report_present, PDF-or-Markdown=$alternate_report_present. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
