#!/usr/bin/env bash
set -u

# Grade Lab 01 screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME]
#
# GitHub Actions example:
#   tests/Lab1/test.sh \
#     work/submissions/Student/CC/Labs/Lab01 \
#     10
#
# Manual example:
#   bash tests/Lab1/test.sh \
#     /path/to/CC/Labs/Lab01 \
#     10 \
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

for command in tesseract python3 git node sha256sum realpath xargs; do
  command -v "$command" >/dev/null 2>&1 || {
    if command -v node >/dev/null 2>&1; then
      json_error "Required grading tool is missing: $command"
    fi
    printf '%s\n' "{\"score\":0,\"feedback\":\"Required grading tool is missing: $command\"}"
    exit 0
  }
done

python3 - <<'PY' >/dev/null 2>&1 || json_error "Python Pillow is required for image validation and duplicate detection."
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
solution_pdf="$submission_dir/Lab1_Solution.pdf"

if [[ ! -d "$screenshots_dir" ]]; then
  json_error "Required directory is missing: Labs/Lab01/screenshots"
fi

# Username priority:
# 1. Third command-line argument (manual grading)
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
# filename|identity checks|OCR evidence groups separated by ;;
#
# Identity flags:
#   none     - no username requirement for this screenshot
#   username - GitHub username must appear somewhere
#   prompt   - <github-username>@ubuntu must appear
#   ipv4     - a non-loopback IPv4 address must appear
#
# Each ;; separated OCR expression is required. Alternatives inside one
# expression use normal extended-regex parentheses and |.
readarray -t criteria <<'EOF'
lab01_folder_structure.png|none|lab0?1;;screenshots
github_profile.png|username|(overview|repositories|projects|followers|following|profile)
github_actual_name.png|none|(public[[:space:]]+profile|edit[[:space:]]+profile|profile);;name
portal_login_page.png|none|(student.*marks|marks.*portal|continue[[:space:]]+with[[:space:]]+github)
portal_github_profile.png|username|(profile|account|github)
portal_enrollment_submitted.png|none|20[0-9]{2}[-[:space:]][a-z]{2,4}[-[:space:]][0-9]{1,3};;(pending|submitted|approval|enrollment);;(course|section)
vmware_workstation.png|none|vmware;;workstation
ubuntu_server_iso.png|none|ubuntu;;server;;(iso|\.iso)
available_storage.png|none|(free|available);;(gb|gib|storage|space)
vm_creation_wizard.png|none|(new[[:space:]]+virtual[[:space:]]+machine|virtual[[:space:]]+machine[[:space:]]+wizard)
vm_typical_configuration.png|none|typical;;recommended
vm_ubuntu_iso_selected.png|none|(installer[[:space:]]+disc|image[[:space:]]+file|iso);;ubuntu
vm_configuration_summary.png|none|virtual[[:space:]]+machine;;(disk|storage);;(memory|processor|hardware|summary)
ubuntu_installer_boot.png|none|ubuntu;;(server|install|installer)
ubuntu_language.png|none|(language|english|welcome)
ubuntu_keyboard_layout.png|none|keyboard;;layout
ubuntu_keyboard_variant.png|none|(keyboard|layout);;variant
ubuntu_installation_type.png|none|ubuntu;;server;;(install|installation)
ubuntu_network_interface.png|none|(network|connections);;(eth[0-9]*|ens[0-9]+|enp[0-9a-z]+|dhcp)
ubuntu_installer_network.png|ipv4|(network|connections|dhcp|automatic)
ubuntu_guided_storage.png|none|(guided|use[[:space:]]+an[[:space:]]+entire[[:space:]]+disk|storage)
ubuntu_storage_configuration.png|none|(storage|filesystem);;(disk|partition|mount)
ubuntu_selected_disk.png|none|(choose|select);;(disk|install)
ubuntu_disk_details.png|none|(disk|drive);;([0-9]+([.][0-9]+)?[[:space:]]*(gb|gib)|qemu|vmware)
ubuntu_partition_layout.png|none|(file[[:space:]]*system|partition|mount[[:space:]]+point);;(size|device)
ubuntu_storage_warning.png|none|(confirm[[:space:]]+destructive[[:space:]]+action|loss[[:space:]]+of[[:space:]]+data|are[[:space:]]+you[[:space:]]+sure)
ubuntu_storage_confirmed.png|none|(continue|confirm);;(destructive|installation|changes)
ubuntu_actual_name.png|none|(profile[[:space:]]+setup|your[[:space:]]+name)
ubuntu_server_name.png|none|(server.*name|hostname);;ubuntu
ubuntu_username.png|username|(pick[[:space:]]+a[[:space:]]+username|username)
ubuntu_profile_setup.png|username|profile[[:space:]]+setup;;ubuntu
ubuntu_installation_progress.png|none|(installing|installation|system[[:space:]]+install|update)
ubuntu_installation_complete.png|none|(installation[[:space:]]+complete|reboot[[:space:]]+now)
ubuntu_login_screen.png|none|ubuntu;;login
ubuntu_terminal_login.png|prompt|(welcome|last[[:space:]]+login|ubuntu)
ubuntu_identity_verified.png|prompt|ubuntu
ubuntu_ip_addr_command.png|prompt|ip[[:space:]]+addr;;inet
ubuntu_ip_address.png|prompt,ipv4|inet
windows_ssh_command.png|username|ssh[[:space:]]+[^[:space:]]+@([0-9]{1,3}[.]){3}[0-9]{1,3}
windows_ssh_fingerprint.png|username|(authenticity|fingerprint|continue[[:space:]]+connecting|yes)
windows_ssh_login.png|prompt|(welcome|last[[:space:]]+login|ubuntu)
windows_ssh_identity.png|prompt|ubuntu
solution_title_page.png|username|lab[[:space:]]*0?1;;20[0-9]{2}[-[:space:]][a-z]{2,4}[-[:space:]][0-9]{1,3};;(course|section)
lab1_solution_pdf.png|none|lab[[:space:]_]*1[[:space:]_]*solution;;pdf
EOF

required_screenshots=${#criteria[@]}

# OCR all available screenshots concurrently. OCR_JOBS may be overridden in
# the workflow; four workers is a safe default for GitHub-hosted runners.
ocr_dir="$(mktemp -d "/tmp/lab1-ocr-${normalized_username}.XXXXXX")"
cleanup() {
  rm -rf -- "$ocr_dir"
  if [[ -n "${reference_hashes:-}" ]]; then
    rm -f -- "$reference_hashes"
  fi
}
trap cleanup EXIT

ocr_jobs="${OCR_JOBS:-4}"
if [[ ! "$ocr_jobs" =~ ^[1-9][0-9]*$ ]]; then
  ocr_jobs=4
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

# Create one duplicate index for the complete grading run. Screenshots with
# the same task filename are compared across students. Exact copies are
# rejected for every task. Perceptual near-duplicate checks are limited to
# identity-bearing screenshots because ordinary Ubuntu installer screens can
# legitimately look almost identical for different students.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/lab1-duplicate-images-${duplicate_key}.tsv"

  if [[ ! -f "$duplicate_index" ]]; then
    python3 - "$submissions_root" "$relative_screenshots" "$duplicate_index" <<'PY'
import hashlib
import itertools
import pathlib
import sys
from collections import defaultdict
from PIL import Image, ImageOps

root = pathlib.Path(sys.argv[1]).resolve()
relative = pathlib.PurePosixPath(sys.argv[2])
output = pathlib.Path(sys.argv[3])
groups = defaultdict(list)

identity_files = {
    "github_profile.png",
    "portal_github_profile.png",
    "ubuntu_username.png",
    "ubuntu_profile_setup.png",
    "ubuntu_terminal_login.png",
    "ubuntu_identity_verified.png",
    "ubuntu_ip_addr_command.png",
    "ubuntu_ip_address.png",
    "windows_ssh_command.png",
    "windows_ssh_fingerprint.png",
    "windows_ssh_login.png",
    "windows_ssh_identity.png",
    "solution_title_page.png",
}

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file() and image.suffix.lower() in {".png", ".jpg", ".jpeg"}:
            groups[image.name.lower()].append(image.resolve())

def exact_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def dhash(path):
    with Image.open(path) as source:
        image = ImageOps.exif_transpose(source).convert("L").resize((9, 8))
        pixels = list(image.getdata())
    value = 0
    for row in range(8):
        for column in range(8):
            value = (value << 1) | (
                pixels[row * 9 + column] > pixels[row * 9 + column + 1]
            )
    return value

duplicates = {}
for filename, paths in groups.items():
    fingerprints = {}
    for image in paths:
        try:
            fingerprints[image] = (exact_hash(image), dhash(image))
        except Exception:
            continue

    for left, right in itertools.combinations(fingerprints, 2):
        left_sha, left_dhash = fingerprints[left]
        right_sha, right_dhash = fingerprints[right]

        if left_sha == right_sha:
            duplicates[left] = "exact duplicate of another student's same task"
            duplicates[right] = "exact duplicate of another student's same task"
            continue

        if filename in identity_files:
            distance = (left_dhash ^ right_dhash).bit_count()
            if distance <= 2:
                duplicates[left] = "near-duplicate of another student's identity evidence"
                duplicates[right] = "near-duplicate of another student's identity evidence"

output.write_text(
    "".join(f"{path}\t{reason}\n" for path, reason in sorted(duplicates.items())),
    encoding="utf-8",
)
PY
  fi
fi

# Build SHA-256 hashes for the instructor-provided reference images. An exact
# copy of a reference image is not valid student evidence.
reference_hashes="$(mktemp "/tmp/lab1-reference-hashes.XXXXXX")"
if [[ -d "$submission_dir/images/install-ubuntu-server" ]]; then
  find "$submission_dir/images/install-ubuntu-server" -type f -print0 2>/dev/null |
    xargs -0 -r sha256sum 2>/dev/null |
    awk '{print $1}' |
    sort -u > "$reference_hashes"
fi

passed=0
feedback=()

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  remainder="${rule#*|}"
  identity_flags="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  image="$screenshots_dir/$filename"

  if [[ ! -f "$image" ]]; then
    feedback+=("$filename: missing (0)")
    continue
  fi

  # Verify that Pillow can decode the image. No minimum-dimension rule is used.
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

  image_sha="$(sha256sum "$image" | awk '{print $1}')"
  if [[ -s "$reference_hashes" ]] && grep -Fqx "$image_sha" "$reference_hashes"; then
    feedback+=("$filename: copied instructor reference image (0)")
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

  if [[ ",$identity_flags," == *,username,* ]]; then
    if ! grep -Eqi "(^|[^[:alnum:]-])${escaped_username}([^[:alnum:]-]|$)" <<<"$ocr_text"; then
      feedback+=("$filename: GitHub username was not clearly detected (0)")
      continue
    fi
  fi

  if [[ ",$identity_flags," == *,prompt,* ]]; then
    if ! grep -Eqi "${escaped_username}[[:space:]]*@[[:space:]]*ubuntu" <<<"$ocr_text"; then
      feedback+=("$filename: ${github_username}@ubuntu prompt was not clearly detected (0)")
      continue
    fi
  fi

  if [[ ",$identity_flags," == *,ipv4,* ]]; then
    if ! grep -Eo '([0-9]{1,3}[.]){3}[0-9]{1,3}' <<<"$ocr_text" |
      grep -Ev '^(127\.|0\.0\.0\.0$|255\.255\.255\.255$)' >/dev/null; then
      feedback+=("$filename: non-loopback IPv4 address was not clearly detected (0)")
      continue
    fi
  fi

  evidence_ok=true
  missing_evidence=""
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    if ! grep -Eqi -- "$evidence_pattern" <<<"$ocr_text"; then
      evidence_ok=false
      missing_evidence="$evidence_pattern"
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

# Lab1_Solution.pdf is one additional equal-weight deliverable.
if [[ ! -f "$solution_pdf" ]]; then
  feedback+=("Lab1_Solution.pdf: missing (0)")
else
  pdf_header="$(head -c 5 "$solution_pdf" 2>/dev/null || true)"
  pdf_size="$(wc -c < "$solution_pdf" 2>/dev/null || printf '0')"
  if [[ "$pdf_header" != "%PDF-" || "$pdf_size" -lt 1024 ]]; then
    feedback+=("Lab1_Solution.pdf: invalid or empty PDF (0)")
  else
    passed=$((passed + 1))
    feedback+=("Lab1_Solution.pdf: passed")
  fi
fi

required=$((required_screenshots + 1))

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

summary="Passed $passed/$required Lab 01 checks. $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2]
  }))
' "$score" "$summary"
