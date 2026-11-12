#!/usr/bin/env bash
set -euo pipefail

# DevOps Lab 05: the live rubric and Lab 05-only OCR retry are defined here.
# The shared scoring and OCR helpers are used without modifications.
# Usage: bash tests/DevOps/Lab5/test.sh SUBMISSION TOTAL_MARKS [GITHUB_USERNAME]
# Student code, builds, and containers are never executed.
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$test_directory" "$@" <<'PY'
from argparse import ArgumentParser
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

TEST_DIRECTORY = Path(sys.argv[1])
sys.path.insert(0, str(TEST_DIRECTORY.parent))
import evidence_grader as shared


def criterion(filename, task, label, *required, retry_terminal=False):
    check = {
        "filename": filename,
        "task": task,
        "label": label,
        "required": [{"label": description, "pattern": pattern} for description, pattern in required],
    }
    if retry_terminal:
        check["terminal_ocr_retry"] = True
    return check


DOCKER_IMAGE_ROW = "lab5:1.0 image row with image ID"

RUBRIC = {
    "lab": 5,
    "source_url": "https://github.com/WaqasSaleem97/DevOps_F26/blob/a4e0d5bac6b167e0663b013e8bf23058d833f613/Labs/Lab05/README.md",
    "source_commit": "a4e0d5bac6b167e0663b013e8bf23058d833f613",
    "screenshot_count": 37,
    "solution_pdf": "Lab5_Solution.pdf",
    "scoring": "Each required screenshot and the valid solution PDF is one equal-weight check.",
    "screenshots": [
        criterion(
            "intellij_repo_clone.png", 1, "Clone the IntelliJ Docker repository",
            ("git clone command", r'''git\s+clone'''),
            ("Intellij-Idea-docker repository", r'''github[.]com/WaqasSaleem97/Intellij-Idea-docker'''),
            ("Successful clone output", r'''Cloning\s+into|Receiving\s+objects|Resolving\s+deltas|done[.]'''),
        ),
        criterion(
            "intellij_running.png", 1, "Launch the IntelliJ desktop",
            ("docker compose ps command", r'''docker\s+compose\s+ps'''),
            ("intellij service", r'''intellij'''),
            ("Running service", r'''\bUp\b|\brunning\b'''),
            ("Published desktop port 3001", r'''3001'''),
        ),
        criterion(
            "intellij_desktop.png", 1, "IntelliJ Welcome screen in the browser desktop",
            ("IntelliJ application", r'''IntelliJ\s+IDEA'''),
            ("Welcome screen", r'''Welcome|New\s+Project|Clone\s+Repository'''),
        ),
        criterion(
            "maven_project_clone.png", 2, "Clone the Maven project",
            ("Clone Repository / Get from Version Control dialog", r'''clone\s+repository|repository\s+url|get\s+from\s+version\s+control'''),
            ("Source repository URL", r'''gitlab\.com/nanuchi/java-maven-app(?:\.git)?'''),
            ("Destination under /config/IdeaProjects", r'''/config/IdeaProjects/java-maven-app'''),
        ),
        criterion(
            "maven_installed.png", 2, "Maven installation and version",
            ("mvn --version command", r'''\bmvn\s+(?:--version|-v)\b'''),
            ("Installed Maven version", r'''Apache\s+Maven\s+\d+[.]\d+'''),
        ),
        criterion(
            "maven_package.png", 2, "Package the Maven application",
            ("mvn package command", r'''\bmvn\s+package\b'''),
            ("Maven BUILD SUCCESS", r'''\bBUILD\s+SUCCESS\b(?!FUL)'''),
        ),
        criterion(
            "maven_elasticsearch_dependency.png", 2, "Elasticsearch dependency in Maven and synchronized library",
            ("pom.xml", r'''pom[.]xml'''),
            ("Elasticsearch group", r'''org[.]elasticsearch'''),
            ("Elasticsearch artifact", r'''elasticsearch'''),
            ("Dependency version 7.0.0", r'''7[.]0[.]0'''),
            ("Compile scope", r'''compile'''),
            ("Synchronized dependency/library view", r'''Dependencies|External\s+Libraries|Maven:\s*org[.]elasticsearch'''),
        ),
        criterion(
            "maven_repackage.png", 2, "Package the Maven application",
            ("mvn package command", r'''\bmvn\s+package\b'''),
            ("Maven BUILD SUCCESS", r'''\bBUILD\s+SUCCESS\b(?!FUL)'''),
        ),
        criterion(
            "maven_test.png", 2, "Run Maven tests",
            ("mvn test command", r'''\bmvn\s+test\b'''),
            ("Maven BUILD SUCCESS", r'''\bBUILD\s+SUCCESS\b(?!FUL)'''),
            ("Actual test-phase result", r'''No\s+tests\s+to\s+run|Tests\s+run|maven-surefire-plugin|\bsurefire\b'''),
        ),
        criterion(
            "maven_jar.png", 2, "Generated Maven JAR",
            ("target output directory", r'''\btarget\b'''),
            ("Maven JAR filename", r'''(?<![\w.-])java[ \t]*-[ \t]*maven[ \t]*-[ \t]*app[ \t]*-[ \t]*1[ \t]*[.][ \t]*1[ \t]*[.][ \t]*0[ \t]*-[ \t]*SNAPSHOT[ \t]*[.][ \t]*jar(?![\w.-])'''),
        ),
        criterion(
            "maven_running.png", 2, "Run the Maven JAR",
            ("java -jar command and Maven artifact", r'''\bjava[ \t]+[-–—][ \t]*jar\s+(?:[.][ \t]*/[ \t]*)?target[ \t]*/[ \t]*java[ \t]*-[ \t]*maven[ \t]*-[ \t]*app[ \t]*-[ \t]*1[ \t]*[.][ \t]*1[ \t]*[.][ \t]*0[ \t]*-[ \t]*SNAPSHOT[ \t]*[.][ \t]*jar(?![\w.-])'''),
            ("Successful Spring Boot / Tomcat startup", r'''Tomcat\s+started|Started\s+\S+.*\bin\s+[\d.]+\s+seconds|Started.*Application'''),
        ),
        criterion(
            "maven_stopped.png", 2, "Stop the Maven application",
            ("Ctrl+C or shutdown output", r'''\^C|shutting\s+down|shutdown|Stopping\s+service'''),
        ),
        criterion(
            "maven_project_closed.png", 2, "Close the Maven project",
            ("IntelliJ Welcome screen", r'''Welcome\s+to\s+IntelliJ|IntelliJ\s+IDEA'''),
            ("Welcome actions after closing the project", r'''New\s+Project'''),
            ("Open or Clone Repository action", r'''Clone\s+Repository|Get\s+from\s+Version\s+Control|\bOpen\b'''),
        ),
        criterion(
            "gradle_project_clone.png", 3, "Clone the Gradle project",
            ("Clone Repository / Get from Version Control dialog", r'''clone\s+repository|repository\s+url|get\s+from\s+version\s+control'''),
            ("Source repository URL", r'''gitlab\.com/nanuchi/java-app(?:\.git)?'''),
            ("Destination under /config/IdeaProjects", r'''/config/IdeaProjects/java-app'''),
        ),
        criterion(
            "gradle_build.png", 3, "Build the Gradle application",
            ("./gradlew build command", r'''[.]/gradlew\s+build\b'''),
            ("Gradle BUILD SUCCESSFUL", r'''\bBUILD\s+SUCCESSFUL\b'''),
        ),
        criterion(
            "gradle_elasticsearch_dependency.png", 3, "Elasticsearch dependency in Gradle and synchronized library",
            ("build.gradle", r'''build[.]gradle'''),
            ("implementation dependency declaration", r'''\bimplementation\b'''),
            ("Elasticsearch group/artifact", r'''org[.]elasticsearch\s*:\s*elasticsearch'''),
            ("Version 7.0.0", r'''7[.]0[.]0'''),
            ("Synchronized library view", r'''External\s+Libraries|Gradle:\s*org[.]elasticsearch'''),
        ),
        criterion(
            "gradle_rebuild.png", 3, "Build the Gradle application",
            ("./gradlew build command", r'''[.]/gradlew\s+build\b'''),
            ("Gradle BUILD SUCCESSFUL", r'''\bBUILD\s+SUCCESSFUL\b'''),
        ),
        criterion(
            "gradle_jar.png", 3, "Generated Gradle JAR",
            ("build/libs output directories", r'''\bbuild\b[\s\S]*\blibs\b'''),
            ("Gradle JAR filename", r'''(?<![\w.-])java[ \t]*-[ \t]*app[ \t]*-[ \t]*1[ \t]*[.][ \t]*0[ \t]*-[ \t]*SNAPSHOT[ \t]*[.][ \t]*jar(?![\w.-])'''),
        ),
        criterion(
            "gradle_running.png", 3, "Run the Gradle JAR",
            ("java -jar command and Gradle artifact", r'''\bjava[ \t]+[-–—][ \t]*jar\s+(?:[.][ \t]*/[ \t]*)?build[ \t]*/[ \t]*libs[ \t]*/[ \t]*java[ \t]*-[ \t]*app[ \t]*-[ \t]*1[ \t]*[.][ \t]*0[ \t]*-[ \t]*SNAPSHOT[ \t]*[.][ \t]*jar(?![\w.-])'''),
            ("Successful Spring Boot / Tomcat startup", r'''Tomcat\s+started|Started\s+\S+.*\bin\s+[\d.]+\s+seconds|Started.*Application'''),
        ),
        criterion(
            "gradle_stopped.png", 3, "Stop the Gradle application",
            ("Ctrl+C or shutdown output", r'''\^C|shutting\s+down|shutdown|Stopping\s+service'''),
        ),
        criterion(
            "gradle_project_closed.png", 3, "Close the Gradle project",
            ("IntelliJ Welcome screen", r'''Welcome\s+to\s+IntelliJ|IntelliJ\s+IDEA'''),
            ("Welcome actions after closing the project", r'''New\s+Project'''),
            ("Open or Clone Repository action", r'''Clone\s+Repository|Get\s+from\s+Version\s+Control|\bOpen\b'''),
        ),
        criterion(
            "node_project_clone.png", 4, "Clone the Node.js project",
            ("Clone Repository / Get from Version Control dialog", r'''clone\s+repository|repository\s+url|get\s+from\s+version\s+control'''),
            ("Source repository URL", r'''gitlab\.com/devopsbootcamp3/node-project(?:\.git)?'''),
            ("Destination under /config/IdeaProjects", r'''/config/IdeaProjects/node-project'''),
        ),
        criterion(
            "nodejs_installed.png", 4, "Node.js and npm versions",
            ("node --version command and version", r'''node\s+(?:--version|-v)[\s\S]*?\bv?\d+[.]\d+[.]\d+'''),
            ("npm --version command and version", r'''npm\s+(?:--version|-v)[\s\S]*?\b\d+[.]\d+[.]\d+'''),
        ),
        criterion(
            "npm_install.png", 4, "Install Node.js app dependencies",
            ("npm install command", r'''npm\s+install'''),
            ("Completed dependency installation", r'''added\s+\d+.*packages|up\s+to\s+date|audited\s+\d+\s+packages'''),
        ),
        criterion(
            "node_running.png", 4, "Node.js application listening on port 4000",
            ("npm start command", r'''npm\s+start'''),
            ("Application listening on port 4000", r'''app\s+listening\s+on\s+port\s+4000'''),
        ),
        criterion(
            "node_browser.png", 4, "Node.js profile page at localhost:4000",
            ("Container browser URL port 4000", r'''(?:localhost|127[.]0[.]0[.]1):4000'''),
            ("Profile-page content", r'''profile|username|birth|interests|edit\s+profile|name\s*:|User\s+Profile'''),
        ),
        criterion(
            "npm_test.png", 4, "Passing npm/Jest tests",
            ("npm test command", r'''npm\s+test'''),
            ("Passing Jest result", r'''\bPASS\b|Test\s+Suites:\s*\d+\s+passed|Tests:\s*\d+\s+passed'''),
        ),
        criterion(
            "npm_pack.png", 4, "Create Node.js tarball",
            ("npm pack command", r'''npm\s+pack'''),
            ("Generated tarball filename", r'''bootcamp-node-project-1[.]0[.]0[.]tgz'''),
        ),
        criterion(
            "react_node_project_clone.png", 5, "Clone React/Node.js example",
            ("Clone Repository / Get from Version Control dialog", r'''clone\s+repository|repository\s+url|get\s+from\s+version\s+control'''),
            ("Source repository URL", r'''github\.com/bbachi/react-nodejs-example(?:\.git)?'''),
            ("Destination under /config/IdeaProjects", r'''/config/IdeaProjects/react-nodejs-example'''),
        ),
        criterion(
            "react_api_dependencies.png", 5, "Install API dependencies",
            ("npm install command", r'''npm\s+install'''),
            ("Successful installation", r'''added\s+\d+.*packages|up\s+to\s+date|audited\s+\d+\s+packages'''),
            ("api directory", r'''\bapi\b'''),
            ("node_modules directory", r'''node_modules'''),
        ),
        criterion(
            "react_api_build.png", 5, "Build webpack API bundle",
            ("npm run build command", r'''npm\s+run\s+build'''),
            ("webpack build result", r'''webpack[\s\S]*(?:compiled|built|Hash:|Version:)|\bbuilt\b[\s\S]*webpack'''),
            ("Generated bundle", r'''server[.]bundle[.]js'''),
        ),
        criterion(
            "react_api_bundle.png", 5, "Inspect the generated JavaScript bundle",
            ("cat server.bundle.js piped to more", r'''cat\s+server[.]bundle[.]js\s*\|\s*more'''),
            ("Bundled JavaScript content", r'''webpack|__webpack_require__|function\s*\(|module[.]exports'''),
        ),
        criterion(
            "docker_installed.png", 6, "Docker version",
            ("docker --version command", r'''docker\s+--version'''),
            ("Installed Docker version", r'''Docker\s+version\s+\d+[.]\d+'''),
        ),
        criterion(
            "dockerfile_exists.png", 6, "Locate the Dockerfile in project root",
            ("ls command", r'''(?:^|[$#][ \t]*)[ \t]*ls\b|[$#][ \t]*1s\b'''),
            ("Dockerfile in listing", r'''^(?![^\r\n]*[$#])[ \t]*(?!(?:ls|1s)\b)[^\r\n]*\bDockerfile\b'''),
        ),
        criterion(
            "docker_images_before.png", 6, "Inspect Docker images",
            ("docker images command", r'''docker\s+(?:images|image\s+ls)'''),
            ("Classic or current Docker image-list headings", r'''(?:\bREPOSITORY\b[\s\S]{0,160}\bTAG\b[\s\S]{0,120}\bIMAGE\s+ID\b|\b(?:IMAGE|ITMAGE|1MAGE|MAGE)\s+[I1l]D\b(?=[\s\S]{0,160}\bDISK\s+USAGE\b)(?=[\s\S]{0,160}\bCONTENT\s+SIZE\b))'''),
        ),
        criterion(
            "docker_build.png", 6, "Build lab5:1.0 image",
            ("docker build -t lab5:1.0 . command", r'''docker\s+build\s+-t\s+(?:lab5|[1i]ab5|1lab5)[ \t]*:[ \t]*1[.]0[ \t]*[.](?=\s|$)'''),
            ("Successful legacy or BuildKit image-tag output", r'''(?:Successfully\s+tagged\s+|(?:naming|tagging)\s+to\s+(?:docker[.]io/library/)?)lab5:1[.]0(?![0-9a-z_.-])'''),
            retry_terminal=True,
        ),
        criterion(
            "docker_images_after.png", 6, "Inspect Docker images",
            ("docker images command", r'''docker\s+(?:images|image\s+ls)'''),
            ("Classic or current Docker image-list headings", r'''(?:\bREPOSITORY\b[\s\S]{0,160}\bTAG\b[\s\S]{0,120}\bIMAGE\s+ID\b|\b(?:IMAGE|ITMAGE|1MAGE|MAGE)\s+[I1l]D\b(?=[\s\S]{0,160}\bDISK\s+USAGE\b)(?=[\s\S]{0,160}\bCONTENT\s+SIZE\b))'''),
            (DOCKER_IMAGE_ROW, r'''^[ \t]*(?:[^\w\s]+[ \t]*)?(?:docker[.]io/library/)?lab5(?:[ \t]*:[ \t]*|[ \t]+)1[.]0\s+(?:sha256:)?[0-9a-flo]{12,64}\b'''),
            retry_terminal=True,
        ),
    ],
}
CHECKS = {check["filename"]: check for check in RUBRIC["screenshots"]}

# This additional OCR pass runs only for unclear Lab 05 Docker evidence. Use
# the existing OCR runner with a temporary, high-contrast copy of the image.
TERMINAL_RETRY = """
import math
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from PIL import Image, ImageFilter, ImageOps, ImageStat

sys.path.insert(0, sys.argv[1])
from ocr_screenshot import _dark_panel_bounds, run_tesseract

image_list_pane = sys.argv[3] == "image-list-pane"
with Image.open(sys.argv[2]) as opened:
    image = ImageOps.exif_transpose(opened)
    if image_list_pane:
        image = image.convert("RGB")
        bounds = _dark_panel_bounds(image)
        if not bounds:
            raise SystemExit(0)
        image = image.crop(bounds[0])
        # The repository, tag, and image ID are in the left columns.
        image = image.crop((0, 0, int(image.width * .75), image.height))
        if image.width * image.height > 2_000_000:
            image.thumbnail((1850, 1050))
    gray = image.convert("L")
if image_list_pane:
    gray = ImageOps.autocontrast(ImageOps.invert(gray), cutoff=1)
    gray = gray.resize((gray.width * 2, gray.height * 2), Image.Resampling.LANCZOS)
    border = 14
else:
    if ImageStat.Stat(gray).mean[0] < 127:
        gray = ImageOps.invert(gray)
    gray = ImageOps.autocontrast(gray, cutoff=1)
    pixels = gray.width * gray.height
    if pixels <= 2_250_000:
        gray = gray.resize((gray.width * 2, gray.height * 2), Image.Resampling.LANCZOS)
    elif pixels > 9_000_000:
        scale = math.sqrt(9_000_000 / pixels)
        gray.thumbnail((max(1, int(gray.width * scale)), max(1, int(gray.height * scale))))
    border = 12
gray = ImageOps.expand(gray.filter(ImageFilter.SHARPEN), border=border, fill="white")
with TemporaryDirectory(prefix="lab5-terminal-ocr-") as temporary:
    prepared = Path(temporary) / "terminal.png"
    gray.save(prepared)
    sys.stdout.write(run_tesseract(prepared, 6))
"""


def retry_docker_ocr(image, *, image_list_pane=False):
    try:
        completed = subprocess.run(
            [sys.executable, "-c", TERMINAL_RETRY, str(shared.ROOT / "scripts"), str(image),
             "image-list-pane" if image_list_pane else "full"],
            capture_output=True, encoding="utf-8", errors="replace", check=False, timeout=25,
            env={**os.environ, "OMP_THREAD_LIMIT": "1"},
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return completed.stdout if completed.returncode == 0 else ""


def recover_docker_image_row(image, text, username):
    check = CHECKS["docker_images_after.png"]
    # Retry the small table text only when the command, headers, and identity
    # have already been recognized. Do not infer the tag from a partial row.
    if shared.evidence_problems(check, text, username) != [DOCKER_IMAGE_ROW + " not detected"]:
        return text
    pane = retry_docker_ocr(image, image_list_pane=True)
    row = re.search(
        r"^[ \t]*(?:[^\w\s]+[ \t]*)?"
        r"((?:docker[.]io/library/)?lab5(?:[ \t]*:[ \t]*|[ \t]+)1[.]0[ \t]+"
        r"(?:sha256:)?(?:[0-9a-f]{64}|[0-9a-f]{12}))(?=[ \t]|$)",
        pane, re.IGNORECASE | re.MULTILINE,
    )
    if row:
        return text + "\n\n[Docker image-list pane]\n" + row[1] + "\n"
    return text


def grade_lab5(submission, total, username):
    # Install the Lab 05 OCR adapter only in this test.sh process. Lab 06 and
    # CC use their own entry points and never see this adapter.
    standard_ocr = shared.run_ocr
    audit_setting = os.environ.pop("OCR_AUDIT_DIR", None)
    audit_directory = audit_setting.strip() if audit_setting else ""

    def recognize(image, destination):
        text = standard_ocr(image, destination)
        check = CHECKS.get(destination.stem + ".png")
        if (check and check.get("terminal_ocr_retry") and text.strip()
                and shared.evidence_problems(check, text, username)):
            retry = retry_docker_ocr(image)
            if retry.strip() and retry.strip() != text.strip():
                text += "\n\n[Terminal OCR retry]\n\n" + retry
            if check["filename"] == "docker_images_after.png":
                text = recover_docker_image_row(image, text, username)
        if audit_directory:
            output = Path(audit_directory) / destination.name
            output.parent.mkdir(parents=True, exist_ok=True)
            audit_text = (
                "[REDACTED: OCR contained a visible credential. Inspect the image privately.]\n"
                if shared.credential_visible(text) else text
            )
            output.write_text(audit_text, encoding="utf-8")
        return text

    shared.run_ocr = recognize
    try:
        return shared.grade(submission, total, username, RUBRIC)
    finally:
        shared.run_ocr = standard_ocr
        if audit_setting is not None:
            os.environ["OCR_AUDIT_DIR"] = audit_setting


def main():
    parser = ArgumentParser(prog="test.sh", description="Grade DevOps Lab 05 screenshot and PDF evidence.")
    parser.add_argument("submission", type=Path)
    parser.add_argument("total_marks")
    parser.add_argument("github_username", nargs="?")
    args = parser.parse_args(sys.argv[2:])
    try:
        total = Decimal(args.total_marks)
        if not total.is_finite() or total <= 0:
            raise ValueError("TOTAL_MARKS must be a positive finite number")
        if len(CHECKS) != RUBRIC["screenshot_count"] or len(CHECKS) != len(RUBRIC["screenshots"]):
            raise ValueError("Trusted screenshot count does not match the Lab 05 rubric")
        for command in ("git", "tesseract", "pdfinfo"):
            if not shutil.which(command):
                raise RuntimeError(f"Required grading tool is missing: {command}")
        provided = args.github_username or os.environ.get("STUDENT_GITHUB_USERNAME", "")
        username = shared.normalize_username(provided) if provided else shared.detect_username(args.submission)
        result = grade_lab5(args.submission, total, username)
    except Exception as error:
        print(f"DevOps Lab 05 evidence check failed ({type(error).__name__}); no marks were changed.", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
