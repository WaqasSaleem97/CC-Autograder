#!/usr/bin/env bash
set -u

# Grade Assignment 01 required files and screenshot evidence.
#
# Usage:
#   test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME] [REGISTRATION_NUMBER]
#
# GitHub Actions example:
#   tests/CC/Assignment01/test.sh \
#     work/submissions/Student/CC/Assignments/Assignment01 \
#     10
#
# Manual example:
#   bash tests/CC/Assignment01/test.sh \
#     /path/to/CC/Assignments/Assignment01 \
#     10 \
#     waqassaleem97 \
#     2024-BSE-01

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
  printf '%s\n' '{"score":0,"feedback":"Usage: test.sh SUBMISSION_DIRECTORY TOTAL_MARKS [GITHUB_USERNAME] [REGISTRATION_NUMBER]"}'
  exit 0
fi

submission_input="$1"
total_marks="$2"

for command in tesseract python3 git node sha256sum realpath env timeout xargs find grep sed awk tr cut sort nproc pdfinfo pdftotext pdfimages; do
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
grader_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
registration_number="${4:-${STUDENT_REGISTRATION_NUMBER:-}}"

# The workflow normalizes Screenshots/screenshots before grading. Keep the
# standalone grader equally forgiving when it is run directly.
if [[ ! -d "$screenshots_dir" ]]; then
  alternate_screenshots_dir="$(
    find "$submission_dir" -mindepth 1 -maxdepth 1 -type d -iname screenshots \
      -print -quit 2>/dev/null || true
  )"
  if [[ -n "$alternate_screenshots_dir" ]]; then
    screenshots_dir="$alternate_screenshots_dir"
  fi
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
# filename|identity flag|required OCR expressions separated by ;;
#
# Identity flags:
#   none      - no username requirement
#   username  - the student's GitHub username should appear
#   ubuntu    - the case-insensitive <github-username>@ubuntu prompt should appear
#
# Each expression is one independent task-evidence indicator. A readable image
# earns proportional credit for the indicators OCR can verify instead of losing
# the complete screenshot mark because one word was misread. Alternatives
# inside one expression use normal extended-regex parentheses and |.
readarray -t criteria <<'EOF'
task1_gitea_running.png|ubuntu|((docker|dacker)[[:space:]]+compose[[:space:]]+ps|[dj]o[ck][a-z|]*[^[:alnum:]]+(compose|c[oa][mn][a-z]{2,5}|car[a-z]{2,5}));;gite[as];;(postgres|gitea_db|[gct]ite[as][[:space:]_.-]+d[bsoc]|g[eo]stg[er][ea][es]|[[:space:]]db[[:space:]]);;(up|running|healthy);;(gite[as].{0,24}(status|statue|ststus|gangs)[^[:alnum:]]*2[0-9oe8]{2}|http[[:space:]]+(status|statue|ststus).*2[0-9oe8]{2}|http/[12]([.][0-9]+)?[[:space:]]+2[0-9]{2}([[:space:]]+ok)?|(127[.]0[.]0[.]1|localhost):3000.*[[:space:]]2[0-9oe8]{2}([[:space:]]|$))
task1_gitea_repository.png|none|(gitea|:[[:space:]]*3000|repositories|packages.*releases.*wiki.*activity);;assignment[[:space:]_@-]*[0o]?[1li];;readme;;(assignment[[:space:]_@-]*[0o]?[1li].{0,24}pub[li1]?ic|pub[li1]?ic.{0,24}assignment[[:space:]_@-]*[0o]?[1li]|20[0-9]{2}[-[:space:]]*[a-z]{2,4}[-[:space:]]*[0-9]{1,3}|fa[0-9]{2}[a-z0-9-]{4,}|registration|roll[[:space:]]*(number|no))
task1_gitea_push.png|ubuntu|git[[:space:]]+push([[:space:]]+[-]?u)?[[:space:]]+[gq]?[i1l]tea[[:space:]]+main;;([gq]?[i1l]tea|:[[:space:]]*3000);;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|track.*gitea/main|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_github_push.png|ubuntu|git[[:space:]]+push([[:space:]]+[-]?u)?[[:space:]]+([gj][i1l]t[hnu]u[b8]|https?[^[:space:]]*[gj][i1l]t[hnu]u[b8][.]c[oa]m)[^[:space:]]*[[:space:]]+main;;[gj][i1l]t[hnu]u[b8]([.]c[oa]m)?;;(new[[:space:]]+branch|set[[:space:]]+up[[:space:]]+to[[:space:]]+track|track.*github/main|everything[[:space:]]+up[[:space:]]+to[[:space:]]+date|main[[:space:]]*->[[:space:]]*main)
task2_remotes.png|ubuntu|git[[:space:]]+remote([[:space:]]+-v)?;;gitea.*(127[.][0o@][.][0o@]([.][li1])?|localhost|:[[:space:]]*[23]?[0o6][0o@][0o@]?);;[gj][i1l]t[hnu]u[b8].*[gj][i1l]t[hnu]u[b8][.]c[oa]m;;fetch;;push
task2_github_repository.png|username|assignment[[:space:]_@-]*[0o]?[1li];;readme;;(github([.]com)?|security[[:space:]]+and[[:space:]]+quality|pull[[:space:]]+requests|insights|agents);;(assignment[[:space:]_@-]*[0o]?[1li].{0,24}(pub[li1]?ic|pubic|usic)|(pub[li1]?ic|pubic|usic).{0,24}assignment[[:space:]_@-]*[0o]?[1li]);;(20[0-9]{2}[-[:space:]]*[a-z]{2,4}[-[:space:]]*[0-9]{1,3}|fa[0-9]{2}[a-z0-9-]{4,}|registration|roll[[:space:]]*(number|no))
task3_lfs_setup.png|ubuntu|(git[[:space:]]+[li1]{0,2}fs[[:space:]]+install|git[[:space:]]+[li1]{0,2}fs[[:space:]]+initialized|[li1]{0,2}fs[[:space:]]+initialized);;(git[[:space:]]+[li1]{0,2}fs[[:space:]]+version|git-[li1]{0,2}fs/[0-9]);;git[[:space:]]+[li1]{0,2}fs[[:space:]]+track;;gitattributes;;[.]bin
task3_lfs_files.png|ubuntu|git[[:space:]]+[li1]{0,2}fs[[:space:]]+[li1]?s-files([[:space:]]+--size)?;;[.]bin
task3_lfs_push.png|ubuntu|git[[:space:]]+push([[:space:]]+[-]?u)?[[:space:]]+([gj][i1l]t[hnu]u[b8]|https?[^[:space:]]*[gj][i1l]t[hnu]u[b8][.]c[oa]m)[^[:space:]]*[[:space:]]+main;;(uploading[[:space:]]+[li1]{0,2}fs[[:space:]]+objects?|[li1]{0,2}fs[[:space:]]+objects?);;(100%|3[[:space:]]*/[[:space:]]*3);;[gj][i1l]t[hnu]u[b8]([.]c[oa]m)?
task4_pages_repository.png|username|[gj][i1l]t[hnu]u[b8][.]io;;index[.]?htm[li1t];;styles[.]css;;pub[li1]?ic
task4_pages_deployment.png|username|github[[:space:]_-]*pages;;(deployed|deployment|published|active|success|your[[:space:]]+site[[:space:]]+is[[:space:]]+live);;[gj][i1l]t[hnu]u[b8][.]io
task4_portfolio_live.png|username|[gj][i1l]t[hnu]u[b8][.]io;;(portfolio|curriculum[[:space:]]+vitae|cv|about[[:space:]]+(me|hie)|education|ski[li1]t?s|projects|software[[:space:]]+engineering.*cloud[[:space:]]+computing)
EOF

required=${#criteria[@]}

declare -A task_anchors=(
  [task1_gitea_running.png]="((docker|dacker)[[:space:]]+compose[[:space:]]+ps|[dj]o[ck][a-z|]*[^[:alnum:]]+(compose|c[oa][mn][a-z]{2,5}|car[a-z]{2,5})|gite[as].{0,24}(status|statue|ststus|gangs)[^[:alnum:]]*2[0-9oe8]{2}|http/[12]([.][0-9]+)?[[:space:]]+2[0-9]{2}|[gct]ite[as][[:space:]_.-]+d[bsoc].*(up|running|healthy)|postgres.*(up|running|healthy))"
  [task1_gitea_repository.png]="((gitea|:[[:space:]]*3000).*(assignment[[:space:]_@-]*[0o]?[1li])|(assignment[[:space:]_@-]*[0o]?[1li]).*(gitea|:[[:space:]]*3000)|(repositories|packages|public[[:space:]]+activity).*(assignment[[:space:]_@-]*[0o]?[1li])|(assignment[[:space:]_@-]*[0o]?[1li]).*(repositories|packages|public[[:space:]]+activity))"
  [task1_gitea_push.png]="(git[[:space:]]+push.*[gq]?[i1l]tea|[gq]?[i1l]tea/main|127[.]0[.]0[.]1:3000.*assignment[[:space:]_@-]*[0o]?[1li])"
  [task2_github_push.png]="(git[[:space:]]+push.*([gj][i1l]t[hnu]u[b8]|github[.]com)|github/main|github[.]com.*assignment[[:space:]_@-]*[0o]?[1li])"
  [task2_remotes.png]="(git[[:space:]]+remote([[:space:]]+-v)?|gitea.*github|github.*gitea)"
  [task2_github_repository.png]="(github[.]com.*assignment[[:space:]_@-]*[0o]?[1li]|assignment[[:space:]_@-]*[0o]?[1li].*(code|issues|pull[[:space:]]+requests|actions|github))"
  [task3_lfs_setup.png]="(git[[:space:]]+[li1]{0,2}fs[[:space:]]+(install|version|track)|gitattributes.*[.]bin)"
  [task3_lfs_files.png]="(git[[:space:]]+[li1]{0,2}fs[[:space:]]+[li1]?s-files|[a-f0-9]{6,}.*[.]bin)"
  [task3_lfs_push.png]="(uploading[[:space:]]+[li1]{0,2}fs[[:space:]]+objects?|[li1]{0,2}fs[[:space:]]+objects?|git[[:space:]]+push.*([gj][i1l]t[hnu]u[b8]|github[.]com)|to[[:space:]]+https?://[^[:space:]]*[gj][i1l]t[hnu]u[b8][.]c[oa]m.*main[[:space:]]*[-=]+>[[:space:]]*main)"
  [task4_pages_repository.png]="([gj][i1l]t[hnu]u[b8][.]io|[gj][i1l]t[hnu]u[b8][.]io.*(index|styles|pub[li1]?ic)|(index|styles).*[gj][i1l]t[hnu]u[b8][.]io)"
  [task4_pages_deployment.png]="(github[[:space:]_-]*pages|([gj][i1l]t[hnu]u[b8][.]io).*(deployed|published|active|live|success)|(deployed|published|active|live|success).*[gj][i1l]t[hnu]u[b8][.]io)"
  [task4_portfolio_live.png]="([gj][i1l]t[hnu]u[b8][.]io.*(portfolio|curriculum[[:space:]]+vitae|cv|about|education|ski[li1]t?s|projects)|(portfolio|curriculum[[:space:]]+vitae|about[[:space:]]+(me|hie)|education|ski[li1]t?s|projects).*[gj][i1l]t[hnu]u[b8][.]io|about[[:space:]]+(me|hie).*education|education.*ski[li1]t?s|ski[li1]t?s.*projects|software[[:space:]]+engineering.*cloud[[:space:]]+computing)"
)

declare -A evidence_labels=(
  [task1_gitea_running.png]="docker compose ps command;;Gitea container/service;;PostgreSQL container/service;;running status;;successful HTTP 200 response"
  [task1_gitea_repository.png]="Gitea repository page;;Assignment01 repository name;;rendered README;;public status or student registration"
  [task1_gitea_push.png]="git push to gitea main;;Gitea remote or port 3000;;successful push result"
  [task2_github_push.png]="git push to github main;;GitHub destination;;successful push result"
  [task2_remotes.png]="git remote -v command;;Gitea fetch/push URL;;GitHub fetch/push URL;;fetch entries;;push entries"
  [task2_github_repository.png]="Assignment01 repository name;;rendered README;;GitHub repository page;;public repository status;;registration details"
  [task3_lfs_setup.png]="Git LFS initialization;;Git LFS version;;git lfs track command;;.gitattributes output;;*.bin tracking rule"
  [task3_lfs_files.png]="git lfs ls-files --size command;;.bin entries"
  [task3_lfs_push.png]="git push to GitHub;;LFS object upload;;100% or 3/3 completion;;GitHub destination"
  [task4_pages_repository.png]="<username>.github.io repository;;index.html;;styles.css;;public repository status"
  [task4_pages_deployment.png]="GitHub Pages settings;;successful deployment status;;github.io URL"
  [task4_portfolio_live.png]="live github.io URL;;required portfolio content"
)

# Required deliverables account for 10% of the score. Filenames are matched
# case-insensitively, but each file must be a valid non-empty file of its type.
readarray -t artifact_criteria <<'EOF'
Assignment01.md|markdown
Assignment01_Solution.docx|docx
Assignment01_Solution.pdf|pdf
EOF
artifact_required=${#artifact_criteria[@]}

# Resolve required screenshot stems without considering capitalization, image
# extensions, or repeated extensions such as `.PNG.png`.
expected_screenshots=()
for rule in "${criteria[@]}"; do
  expected_screenshots+=("${rule%%|*}")
done

declare -A resolved_screenshots
if [[ -d "$screenshots_dir" ]]; then
  while IFS=$'\t' read -r expected actual; do
    resolved_screenshots["$expected"]="$actual"
  done < <(
    python3 "$grader_root/scripts/resolve_screenshots.py" \
      "$screenshots_dir" "${expected_screenshots[@]}"
  )
fi

# OCR screenshots concurrently through the shared adaptive helper. It upscales
# small images and adds enhanced passes for dark, narrow, or weak OCR without
# imposing a minimum or required image dimension.
ocr_dir="$(mktemp -d "/tmp/assignment01-ocr-${normalized_username}.XXXXXX")"
cleanup() {
  rm -rf -- "$ocr_dir"
}
trap cleanup EXIT

available_cpus="$(nproc 2>/dev/null || true)"
if [[ ! "$available_cpus" =~ ^[1-9][0-9]*$ ]]; then
  available_cpus=2
fi

export OMP_THREAD_LIMIT="${OMP_THREAD_LIMIT:-1}"
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

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  image="${resolved_screenshots[$filename]:-}"
  [[ -f "$image" ]] && printf '%s\0%s\0' "$filename" "$image"
done |
  env -u GH_TOKEN xargs -0 -r -P "$ocr_jobs" -n 2 \
    bash -c '
      output_directory="$1"
      helper="$2"
      filename="$3"
      source_image="$4"
      python3 "$helper" "$source_image" "$output_directory/${filename%.*}.txt"
    ' _ "$ocr_dir" "$grader_root/scripts/ocr_screenshot.py"

# A terminal prompt elsewhere in the same submission can corroborate the
# prompt-only identity portion of another low-resolution terminal screenshot.
# Browser screenshots must still show the student's own username or URL.
submission_prompt_seen=0
read -r submission_prompt_seen < <(
  python3 - "$grader_root" "$ocr_dir" "$normalized_username" <<'PY'
import pathlib
import sys

grader_root, ocr_directory, username = sys.argv[1:]
sys.path.insert(0, grader_root)
from scripts.ocr_evidence import prompt_matches

text = "\n".join(
    path.read_text(encoding="utf-8", errors="replace")
    for path in pathlib.Path(ocr_directory).glob("*.txt")
)
print(int(prompt_matches(username, text)))
PY
) || true

# OCR-specific recoveries remain tied to text visible in the submitted image.
# In particular, a live site elsewhere cannot replace a missing URL in the
# deployment/live screenshot, and a repository lookup cannot rescue the wrong
# screenshot.
local_indicator_verified() {
  local filename="$1" indicator_index="$2"
  case "$filename:$indicator_index" in
    task2_github_repository.png:4)
      grep -Eqi -- \
        'assignment[[:space:]_@-]*[0o]?[1li].{0,20}(pub[li1]?ic|pubic|usic)' \
        <<<"$ocr_normalized"
      ;;
    task4_pages_repository.png:1|task4_pages_deployment.png:3|task4_portfolio_live.png:1)
      python3 "$grader_root/scripts/ocr_evidence.py" \
        url "$normalized_username" "$ocr_file"
      ;;
    *)
      return 1
      ;;
  esac
}

# Public GitHub checks are deliberately lazy. They run only when OCR misses a
# required source filename in an otherwise verified Pages-repository
# screenshot. One metadata-only clone records the real repository tree without
# downloading its file contents. It cannot replace screenshots, identities,
# terminal commands, deployments, live-site URLs, or portfolio content.
github_pages_tree_loaded=false
github_pages_tree_available=false
github_pages_tree_file="$ocr_dir/pages-repository-tree.txt"

load_github_pages_tree() {
  if [[ "$github_pages_tree_loaded" == true ]]; then
    [[ "$github_pages_tree_available" == true ]]
    return
  fi

  github_pages_tree_loaded=true
  github_pages_tree_available=false
  local repository_url clone_dir attempt
  repository_url="https://github.com/$normalized_username/${normalized_username}.github.io.git"

  for attempt in 1 2; do
    clone_dir="$ocr_dir/pages-repository-$attempt"
    if GIT_TERMINAL_PROMPT=0 timeout 20s git -c protocol.version=2 clone \
      --quiet --depth=1 --filter=blob:none --no-checkout \
      "$repository_url" "$clone_dir" >/dev/null 2>&1; then
      if git -C "$clone_dir" ls-tree -r --name-only HEAD \
        > "$github_pages_tree_file" 2>/dev/null; then
        github_pages_tree_available=true
        return 0
      fi
    fi
  done
  return 1
}

github_pages_file_exists() {
  local required_file="$1"
  load_github_pages_tree || return 1
  grep -Fxi -- "$required_file" "$github_pages_tree_file" >/dev/null
}

github_indicator_verified() {
  local filename="$1" indicator_index="$2"

  case "$filename:$indicator_index" in
    task4_pages_repository.png:2)
      github_pages_file_exists index.html
      ;;
    task4_pages_repository.png:3)
      github_pages_file_exists styles.css
      ;;
    task4_pages_repository.png:4)
      # A successful anonymous clone proves that the repository is public.
      load_github_pages_tree
      ;;
    *)
      return 1
      ;;
  esac
}

# Build one exact-duplicate index for screenshots with the same filename across
# every student selected in this workflow. Both students receive zero for a
# duplicated task screenshot. Images from different tasks are not compared.
repo_root="$(git -C "$submission_dir" rev-parse --show-toplevel 2>/dev/null || true)"
duplicate_index=""

if [[ -n "$repo_root" && "$screenshots_dir" == "$repo_root"/* ]]; then
  submissions_root="$(dirname "$(dirname "$repo_root")")"
  relative_screenshots="${screenshots_dir#"$repo_root"/}"
  duplicate_key="$(printf '%s' "$submissions_root|$relative_screenshots" | sha256sum | cut -c1-16)"
  duplicate_index="/tmp/assignment01-duplicate-images-${duplicate_key}.tsv"

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

def filename_key(name):
    value = name.casefold().rstrip(".")
    while True:
        for extension in image_extensions:
            if value.endswith(extension):
                value = value[:-len(extension)].rstrip(".")
                break
        else:
            return value

for repository in root.glob("*/*"):
    screenshot_dir = repository.joinpath(*relative.parts)
    if not screenshot_dir.is_dir():
        continue
    for image in screenshot_dir.iterdir():
        if image.is_file() and filename_key(image.name):
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

validate_artifact() {
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import pathlib
import re
import subprocess
import sys
import zipfile
from xml.etree import ElementTree

path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
if not path.is_file() or path.stat().st_size == 0:
    raise SystemExit(1)

if kind == "markdown":
    content = path.read_text(encoding="utf-8", errors="ignore")
    if len(re.findall(r"[a-z0-9]", content, flags=re.IGNORECASE)) < 10:
        raise SystemExit(1)
elif kind == "docx":
    if not zipfile.is_zipfile(path):
        raise SystemExit(1)
    with zipfile.ZipFile(path) as document:
        names = set(document.namelist())
        if not {"[Content_Types].xml", "word/document.xml"}.issubset(names):
            raise SystemExit(1)
        root = ElementTree.fromstring(document.read("word/document.xml"))
        text = " ".join(root.itertext())
        media = any(name.startswith("word/media/") for name in names)
        if len(re.findall(r"[a-z0-9]", text, flags=re.IGNORECASE)) < 20 and not media:
            raise SystemExit(1)
elif kind == "pdf":
    with path.open("rb") as document:
        if document.read(5) != b"%PDF-":
            raise SystemExit(1)
    information = subprocess.run(
        ["pdfinfo", str(path)], check=False, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )
    pages = re.search(r"(?m)^Pages:\s*([0-9]+)\s*$", information.stdout)
    if information.returncode != 0 or pages is None or int(pages.group(1)) < 1:
        raise SystemExit(1)
    extracted = subprocess.run(
        ["pdftotext", "-layout", str(path), "-"], check=False,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    images = subprocess.run(
        ["pdfimages", "-list", str(path)], check=False,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    readable_text = len(re.findall(r"[a-z0-9]", extracted.stdout, re.IGNORECASE)) >= 20
    embedded_image = bool(re.search(r"(?m)^\s*[0-9]+\s+[0-9]+\s+", images.stdout))
    if extracted.returncode != 0 or (not readable_text and not embedded_image):
        raise SystemExit(1)
else:
    raise SystemExit(1)
PY
}

artifacts_match() {
  python3 - "$1" "$2" <<'PY' >/dev/null 2>&1
import re
import subprocess
import sys
import zipfile
from xml.etree import ElementTree

with zipfile.ZipFile(sys.argv[1]) as document:
    root = ElementTree.fromstring(document.read("word/document.xml"))
    docx_text = " ".join(root.itertext())
pdf_text = subprocess.run(
    ["pdftotext", "-layout", sys.argv[2], "-"], check=False,
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
).stdout

def words(value):
    return {
        word for word in re.findall(r"[a-z0-9]{3,}", value.casefold())
        if word not in {"the", "and", "for", "with", "from", "this", "that"}
    }

docx_words, pdf_words = words(docx_text), words(pdf_text)
if min(len(docx_words), len(pdf_words)) < 20:
    raise SystemExit(0)
overlap = len(docx_words & pdf_words) / min(len(docx_words), len(pdf_words))
raise SystemExit(0 if overlap >= 0.35 else 1)
PY
}

declare -A artifact_paths artifact_valid artifact_reason
for artifact_rule in "${artifact_criteria[@]}"; do
  artifact_name="${artifact_rule%%|*}"
  artifact_kind="${artifact_rule#*|}"
  artifact_path="$(find "$submission_dir" -maxdepth 1 -type f -iname "$artifact_name" -print -quit)"

  if [[ -z "$artifact_path" ]]; then
    artifact_valid["$artifact_name"]=false
    artifact_reason["$artifact_name"]="missing required assignment file"
  elif ! validate_artifact "$artifact_path" "$artifact_kind"; then
    artifact_valid["$artifact_name"]=false
    artifact_reason["$artifact_name"]="invalid, empty, or unreadable assignment file"
  else
    artifact_paths["$artifact_name"]="$artifact_path"
    artifact_valid["$artifact_name"]=true
  fi
done

docx_name="Assignment01_Solution.docx"
pdf_name="Assignment01_Solution.pdf"
if [[ "${artifact_valid[$docx_name]:-false}" == true && "${artifact_valid[$pdf_name]:-false}" == true ]] &&
   ! artifacts_match "${artifact_paths[$docx_name]}" "${artifact_paths[$pdf_name]}"; then
  artifact_valid["$pdf_name"]=false
  artifact_reason["$pdf_name"]="readable PDF does not match the Word solution"
fi

artifact_passed=0
artifact_feedback=()
for artifact_rule in "${artifact_criteria[@]}"; do
  artifact_name="${artifact_rule%%|*}"
  if [[ "${artifact_valid[$artifact_name]:-false}" == true ]]; then
    artifact_passed=$((artifact_passed + 1))
    artifact_feedback+=("$artifact_name: passed")
  else
    artifact_feedback+=("$artifact_name: ${artifact_reason[$artifact_name]} (0)")
  fi
done

full_credit=0
partial_credit=0
screenshot_credit_units=0
review_count=0
github_supported_checks=0
feedback=("${artifact_feedback[@]}")

for rule in "${criteria[@]}"; do
  filename="${rule%%|*}"
  remainder="${rule#*|}"
  identity_flag="${remainder%%|*}"
  evidence_groups="${remainder#*|}"
  image="${resolved_screenshots[$filename]:-}"

  if [[ "$image" == "__AMBIGUOUS__" ]]; then
    feedback+=("$filename: multiple files match this name when image extensions are ignored (0)")
    continue
  fi

  if [[ -z "$image" || ! -f "$image" ]]; then
    feedback+=("$filename: missing (0)")
    continue
  fi

  # Verify that the submitted file is a decodable image. No minimum dimensions
  # or minimum file-size rule is applied.
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
    review_count=$((review_count + 1))
    feedback+=("$filename: valid image but OCR remained inconclusive after adaptive retries; review required (provisional 0)")
    continue
  fi

  # Reject exposed credentials and private-key bodies. The helper ignores
  # harmless horizontal OCR spacing but deliberately preserves line boundaries;
  # otherwise a normal URL and a later user@ubuntu prompt can form a false
  # password-bearing URL when concatenated.
  if python3 "$grader_root/scripts/ocr_evidence.py" credential "$ocr_file"; then
    feedback+=("$filename: exposed credential, token, password, or private-key material is visible (0)")
    continue
  fi

  # Identity is useful ownership evidence, but OCR uncertainty must not erase
  # otherwise valid task evidence. Fuzzy matching tolerates case differences,
  # inserted spaces, and a small number of OCR substitutions. Identity is 15%
  # of a screenshot check; task evidence is 85%.
  identity_required=false
  identity_verified=true
  identity_corroborated=false
  case "$identity_flag" in
    username)
      identity_required=true
      if ! python3 "$grader_root/scripts/ocr_evidence.py" \
        username "$normalized_username" "$ocr_file"; then
        identity_verified=false
      fi
      ;;
    ubuntu)
      identity_required=true
      if ! python3 "$grader_root/scripts/ocr_evidence.py" \
        prompt "$normalized_username" "$ocr_file"; then
        if [[ "$submission_prompt_seen" == "1" ]]; then
          identity_corroborated=true
        else
          identity_verified=false
        fi
      fi
      ;;
  esac

  # Repair harmless spacing around punctuation before matching commands, URLs,
  # filenames, and IPv4 addresses in noisy OCR output.
  ocr_normalized="$(
    printf '%s' "$ocr_text" |
      sed -E \
        -e 's/[[:space:]]*[.][[:space:]]*/./g' \
        -e 's/[[:space:]]*@[[:space:]]*/@/g' \
        -e 's#[[:space:]]*/[[:space:]]*#/#g' \
        -e 's/[[:space:]]*:[[:space:]]*/:/g' |
      tr '\r\n\t' '   ' |
      tr -s ' '
  )"

  anchor_verified=false
  anchor_pattern="${task_anchors[$filename]:-}"
  if [[ "$filename" == "task4_pages_repository.png" ]]; then
    if python3 "$grader_root/scripts/ocr_evidence.py" \
      repository "$normalized_username" "$ocr_file"; then
      anchor_verified=true
    fi
  elif [[ -n "$anchor_pattern" ]] && grep -Eqi -- "$anchor_pattern" <<<"$ocr_normalized"; then
    anchor_verified=true
  fi

  evidence_total=0
  evidence_matched=0
  evidence_index=0
  missing_labels=()
  readarray -t current_labels < <(
    printf '%s\n' "${evidence_labels[$filename]:-}" | sed 's/;;/\n/g'
  )
  while IFS= read -r evidence_pattern; do
    [[ -z "$evidence_pattern" ]] && continue
    evidence_total=$((evidence_total + 1))
    evidence_index=$((evidence_index + 1))
    indicator_matched=false
    if grep -Eqi -- "$evidence_pattern" <<<"$ocr_normalized"; then
      indicator_matched=true
    elif [[ "$anchor_verified" == true ]] &&
         local_indicator_verified "$filename" "$evidence_index"; then
      indicator_matched=true
    elif [[ "$anchor_verified" == true ]] &&
         github_indicator_verified "$filename" "$evidence_index"; then
      indicator_matched=true
      github_supported_checks=$((github_supported_checks + 1))
    fi
    if [[ "$indicator_matched" == true ]]; then
      evidence_matched=$((evidence_matched + 1))
    else
      missing_labels+=("${current_labels[$((evidence_index - 1))]:-required indicator $evidence_index}")
    fi
  done < <(printf '%s\n' "$evidence_groups" | sed 's/;;/\n/g')

  # The Assignment requires three .bin files and each file must be larger than
  # 100 MiB. Count unique filenames rather than requiring every OCR character
  # in each LFS object hash to be perfect. These are two additional independent
  # indicators, so unclear size text earns partial rather than zero credit.
  if [[ "$filename" == "task3_lfs_files.png" ]]; then
    read -r lfs_entry_count lfs_size_count < <(
      python3 - "$ocr_file" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(
    encoding="utf-8", errors="replace"
).casefold()
text = re.sub(r"\s*[.]\s*", ".", text)
names = set()
large = set()
filename_matches = list(re.finditer(r"[a-z0-9_.@-]+[.]bin", text))
for index, match in enumerate(filename_matches):
    filename = match.group()
    names.add(filename)
    next_filename = (
        filename_matches[index + 1].start()
        if index + 1 < len(filename_matches)
        else len(text)
    )
    # Tesseract often places `(106 MB)` on the line after the filename. Keep
    # the search bounded by the next filename so one size cannot validate a
    # different entry.
    evidence = text[match.end():next_filename]
    sizes = re.findall(
        r"([0-9]+(?:[.][0-9]+)?)\s*(m|mb|mib|g|gb|gib)\b", evidence
    )
    for number, unit in sizes:
        value = float(number)
        if unit.startswith("g") or value > 100:
            large.add(filename)
            break

    if filename in large:
        continue

    # OCR frequently reads the unit in an otherwise clear parenthesized LFS
    # size as `4B`, `#8`, `¥B`, or just `8`. Accept only a 3-4 digit value
    # inside parentheses immediately following an ls-files entry; this cannot
    # be satisfied by a hash, filename, or a separate `truncate` command.
    for noisy_number in re.findall(
        r"\(\s*([0-9o@il]{3,4})\s*[^)]{0,4}\)", evidence
    ):
        cleaned = noisy_number.translate(str.maketrans({
            "o": "0", "@": "0", "i": "1", "l": "1",
        }))
        if cleaned.isdigit() and int(cleaned) > 100:
            large.add(filename)
            break
print(len(names), len(large))
PY
    )
    evidence_total=$((evidence_total + 2))
    if (( lfs_entry_count >= 3 )); then
      evidence_matched=$((evidence_matched + 1))
    else
      missing_labels+=("three different LFS-tracked .bin files")
    fi
    if (( lfs_size_count >= 3 )); then
      evidence_matched=$((evidence_matched + 1))
    else
      missing_labels+=("all three files larger than 100 MiB")
    fi
  fi

  if [[ "$anchor_verified" != true ]]; then
    feedback+=("$filename: required task-specific command or page was not detected (0)")
    continue
  fi

  if (( evidence_total == 0 || evidence_matched == 0 )); then
    feedback+=("$filename: correct task context was detected, but no required result indicator was detected (0)")
    continue
  fi

  if [[ "$identity_required" == true ]]; then
    credit_units=$((850 * evidence_matched / evidence_total))
    if [[ "$identity_verified" == true ]]; then
      credit_units=$((credit_units + 150))
      if [[ "$identity_corroborated" == true ]]; then
        identity_note="identity corroborated elsewhere in the submission"
      else
        identity_note="identity verified"
      fi
    else
      identity_note="identity not detected by OCR"
    fi
  else
    credit_units=$((1000 * evidence_matched / evidence_total))
    identity_note=""
  fi

  screenshot_credit_units=$((screenshot_credit_units + credit_units))
  if (( credit_units == 1000 )); then
    full_credit=$((full_credit + 1))
    feedback+=("$filename: passed")
  else
    partial_credit=$((partial_credit + 1))
    missing_text=""
    if (( ${#missing_labels[@]} > 0 )); then
      printf -v missing_text '%s, ' "${missing_labels[@]}"
      missing_text="${missing_text%, }"
    fi
    if [[ -n "$identity_note" ]]; then
      feedback+=("$filename: partial credit - missing: ${missing_text:-required task evidence}; $identity_note")
    else
      feedback+=("$filename: partial credit - missing: ${missing_text:-required task evidence}")
    fi
  fi
done

# Screenshot evidence accounts for 90% of the marks and the three required
# assignment files account for 10%. Each check inside its component has equal
# weight. Scale both components to the TOTAL_MARKS supplied by the workflow.
score="$(python3 - "$screenshot_credit_units" "$required" "$artifact_passed" "$artifact_required" "$total_marks" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

screenshot_units, screenshot_required, artifact_passed, artifact_required, total = map(
    Decimal, sys.argv[1:]
)
value = (
    screenshot_units / (screenshot_required * Decimal("1000"))
    * total
    * Decimal("0.90")
    + artifact_passed / artifact_required * total * Decimal("0.10")
).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
print(value)
PY
)"

screenshot_equivalent="$(python3 - "$screenshot_credit_units" <<'PY'
from decimal import Decimal, ROUND_HALF_UP
import sys

value = (Decimal(sys.argv[1]) / Decimal("1000")).quantize(
    Decimal("0.01"), rounding=ROUND_HALF_UP
)
print(value)
PY
)"

summary="Earned $screenshot_equivalent/$required screenshot-check equivalents ($full_credit full, $partial_credit partial) and passed $artifact_passed/$artifact_required required assignment-file checks. Public GitHub verification repaired $github_supported_checks OCR indicator(s). $(IFS='; '; echo "${feedback[*]}")"
node -e '
  console.log(JSON.stringify({
    score: Number(process.argv[1]),
    feedback: process.argv[2],
    review_count: Number(process.argv[3])
  }))
' "$score" "$summary" "$review_count"
