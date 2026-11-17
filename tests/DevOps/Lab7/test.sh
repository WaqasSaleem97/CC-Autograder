#!/usr/bin/env bash
set -euo pipefail

# Rubric: https://github.com/WaqasSaleem97/DevOps_F26/blob/06762450ac47afc885d99f5997f2d0a4ba6957c1/Labs/Lab07/README.md
# Usage: bash tests/DevOps/Lab7/test.sh SUBMISSION TOTAL_MARKS [GITHUB_USERNAME]
# Grade the 17 guided-task screenshots only. Never run student code or Docker.
test_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$test_directory" "$@" <<'PY'
from argparse import ArgumentParser
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal, ROUND_HALF_UP
from itertools import islice
import json
import os
from pathlib import Path
import re
import shutil
import sys
from tempfile import TemporaryDirectory
import unicodedata

TEST_DIRECTORY = Path(sys.argv.pop(1))
sys.path.insert(0, str(TEST_DIRECTORY.parent))
import evidence_grader as shared


FLAGS = re.IGNORECASE | re.MULTILINE
DOCKER = r"docker[ \t]+"
CONTAINER = DOCKER + r"(?:container[ \t]+)?"
PROMPT = r"(?:[^\n]{0,150}?[$#%][ \t]*|[a-z0-9-]{1,39}[@g]ubuntu[ \t]*:[^\n]{0,80}?)?"
HUB = r"(?:(?:docker[ \t]*\.[ \t]*io[ \t]*/[ \t]*)?library[ \t]*/[ \t]*)?"
COLON = r"[ \t]*:[ \t]*"
DOT = r"[ \t]*\.[ \t]*"
POSTGRES_96 = rf"{HUB}post[ \t]*gres{COLON}9{DOT}6"
POSTGRES_1010 = rf"{HUB}post[ \t]*gres{COLON}10{DOT}10"
UBUNTU = rf"{HUB}ubuntu(?:{COLON}latest)?"
NGINX = rf"{HUB}nginx"
NGINX_LATEST = rf"{NGINX}(?:{COLON}latest)?"
NGINX_OLDER = rf"{NGINX}{COLON}1{DOT}30{DOT}6"
NGINX_NAME = r"nginx[ \t]*-[ \t]*latest"
NGINX_OLDER_NAME = r"nginx[ \t]*-[ \t]*older"
WEBROOT = r"/[ \t]*usr[ \t]*/[ \t]*share[ \t]*/[ \t]*nginx[ \t]*/[ \t]*html[ \t]*/[ \t]*"
NEWFILE = rf"{WEBROOT}newfile{DOT}html"
OLDFILE = rf"{WEBROOT}oldfile{DOT}html"
HEX = frozenset("0123456789abcdef")
HEX_LOOKALIKES = str.maketrans({
    "o": "0", "@": "0", "i": "1", "l": "1", "|": "1", "s": "5", "g": "9",
    "/": "7", "£": "f", "¢": "c", "€": "c",
})
# The ps row's ID column can be noisy; the image/tag and status must still
# belong to the same row. Ubuntu additionally checks the displayed ID prefix.
ROW_ID = r"[0-9a-folI|/@£¢€#?gst]{12,13}"
ROW_DECORATION = r"[ \t_=~.,;|'’\"-]*"
ID_TEXT = re.compile(r"^[ \t]*[|']?[ \t]*(?:(sha256)[ \t]*:[ \t]*)?([0-9a-z@£¢€#|?!*/.' \t]{12,125})$", FLAGS)
DETACHED = r"(?:--detach(?:=true)?|-[a-z]*d[a-z]*)(?=[ \t])"
HTTP_REQUEST = (r"\bGET\s{1,10}/(?:\?[^ \t\n\"']*)?\s{1,10}HTTP[ \t]*/[ \t]*[12]"
                r"(?:[ \t]*\.[ \t]*[01])?[ \t]*[\"']?\s{1,10}(?:2[0-9o@¢©]{2}|3[0o@¢©]4)(?!\w)")


def terminal(command):
    return rf"^[ \t]*{PROMPT}(?:sudo[ \t]+)?(?:{command})[ \t]*$"


def docker_command(command):
    return terminal(CONTAINER + command)


def follows(command, output, skipped=4):
    return rf"{command}\n(?:(?!{NEXT_DOCKER.pattern})[^\n]*\n){{0,{skipped}}}{output}"


def result_row(image, status):
    # OCR may render a complete table row or put each cell on its own line.
    # Do not borrow a status from a different row or skip a conflicting state.
    ident = rf"[ \t]*['\"]?({ROW_ID})"
    status_start = r"\b(?:Up[ \t]+(?:\d|Less\b|About\b)|Exited[ \t]*\(|Created\b|Restarting\b|Dead\b|Removing\b)"
    inline = (rf"{ROW_DECORATION}[ \t]+{ROW_DECORATION}{image}(?=[ \t])"
              rf"(?:(?!{status_start})[^\n]){{0,260}}?[ \t]+{status}\b")
    next_row = (rf"(?:^[ \t]*['\"]?{ROW_ID}{ROW_DECORATION}(?:[ \t]|$)"
                rf"|^[ \t]*(?:{HUB}post[ \t]*gres|{UBUNTU})(?:{COLON}\S+)?[ \t]*$"
                rf"|^[ \t]*{status_start}|{NEXT_DOCKER.pattern})")
    cell_gap = r"\n(?:[ \t]*\n){0,3}"
    split = (rf"{ROW_DECORATION}{cell_gap}{ROW_DECORATION}{image}[ \t]*"
             rf"(?:{cell_gap}(?:(?!{next_row})[^\n]*\n){{0,13}}[ \t]*"
             rf"|[ \t]+(?:(?!{status_start})[^\n]){{0,160}}?[ \t]+){status}\b")
    return rf"^{ident}(?:{inline}|{split})"


PS_BASE = DOCKER + r"(?:ps|container[ \t]+(?:ls|list|ps))"
NEXT_DOCKER = re.compile(terminal(DOCKER + r"[^\n]{1,250}"), FLAGS)
PS = terminal(PS_BASE)
PS_ALL = terminal(PS_BASE + r"[ \t]+(?:-a|--all)")
CONTAINER_TABLE = r"\bCONTAINER\s+ID\b"
IMAGE_TABLE = (r"\bREPOSITORY\s+TAG\s+IMAGE\s+ID\b"
               r"|\bIMAGE\s+ID\s+DISK\s+USAGE\b"
               r"|\bDISK\s+USAGE\s+CONTENT\s+SIZE\s+EXTRA\b")
UBUNTU_RUN = docker_command(rf"run[ \t]+{DETACHED}[ \t]+{UBUNTU}")
UBUNTU_EXITED = result_row(UBUNTU, r"Exited")
UBUNTU_ROW = result_row(UBUNTU, r"(?:Up|Exited|Created|Restarting|Dead)")


def blocks(command, text, limit=55):
    """Get adjacent output, not unrelated output after a different command."""
    for match in re.finditer(command, text, FLAGS):
        output = []
        if match.end() < len(text):
            for line in islice(text[match.end() + 1:].splitlines(), limit):
                if NEXT_DOCKER.fullmatch(line):
                    break
                output.append(line)
        yield match, "\n".join(output)


def id_key(value):
    return "".join(value.split()).casefold().translate(HEX_LOOKALIKES)


def returned_ids(text, *, digest=False):
    """Find real-looking Docker IDs, including split OCR of a single digest.

    Refuse layer IDs from a pull (usually 12 characters), JSON metadata,
    prose, and lines with "Digest:", "Deleted:" or a trailing pull status.
    """
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = ID_TEXT.fullmatch(line)
        if not match or (match[1] and not digest):
            continue
        chunks = [match[2]]
        for candidate in lines[index + 1:index + 4]:
            if not candidate.strip():
                continue
            more = ID_TEXT.fullmatch(candidate)
            if not more or more[1] or len("".join(chunks).replace(" ", "")) >= 54:
                break
            chunks.append(more[2])
        value = id_key("".join(chunks).strip(" .'"))
        minimum = 12 if digest and match[1] else 54
        if minimum <= len(value) <= 72 and sum(ch in HEX for ch in value) >= len(value) * .88:
            yield value


def matches_id_prefix(left, right):
    prefix = id_key(right)[:12]
    return len(prefix) == 12 and all(ch in HEX for ch in prefix) and left[:12] == prefix


def ubuntu_lists(text, _username):
    running = list(blocks(PS, text))
    all_containers = list(blocks(PS_ALL, text))
    for run, output in blocks(UBUNTU_RUN, text, limit=110):
        for created in returned_ids(output):
            for ps, running_output in running:
                if ps.start() <= run.end() or not re.search(CONTAINER_TABLE, running_output, FLAGS):
                    continue
                if any(matches_id_prefix(created, row[1]) for row in re.finditer(UBUNTU_ROW, running_output, FLAGS)):
                    continue
                for ps_all, all_output in all_containers:
                    if ps_all.start() > ps.end() and any(
                        matches_id_prefix(created, exited[1]) for exited in re.finditer(UBUNTU_EXITED, all_output, FLAGS)
                    ):
                        return True
    return False


TARGET = r"[a-z0-9][a-z0-9_.-]{0,127}(?:[ \t]+[a-z0-9_.-]{1,127}){0,2}"
RESTART = docker_command(rf"restart[ \t]+({TARGET})")
STOP = docker_command(rf"stop[ \t]+({TARGET})")
REMOVE = docker_command(rf"rm[ \t]+({TARGET})")
RMI = terminal(rf"{DOCKER}(?:rmi|image[ \t]+rm)[ \t]+{POSTGRES_96}")
UNTAGGED = rf"^[ \t]*Untagged{COLON}{POSTGRES_96}[ \t]*$"
DOCKER_ERROR = r"^[ \t]*(?:error response from daemon\b|docker:|error:|[-]?bash:)"


def adjacent(first, second, text):
    return second.start() > first.end() and not text[first.end():second.start()].strip()


def cleanup_succeeded(text, _username):
    def target_key(value):
        # OCR sometimes inserts spaces around, or in place of, an underscore
        # in the generated Docker name. Keep the rest of the name exact.
        value = re.sub(r"[ \t]*([_.-])[ \t]*", r"\1", value)
        return re.sub(r"[ \t]+", "_", value).casefold()

    echoed = re.compile(rf"^[ \t]*({TARGET})[ \t]*$", FLAGS)
    actions = [[(m, out) for m, out in blocks(command, text, limit=15)]
               for command in (RESTART, STOP, REMOVE)]
    for untag, output in blocks(RMI, text, limit=30):
        notice = re.search(UNTAGGED, output, FLAGS)
        if not notice or re.search(DOCKER_ERROR, output[:notice.end()], FLAGS):
            continue
        for start, start_out in actions[0]:
            target = target_key(start[1])
            for stop, stop_out in actions[1]:
                if not start.end() < stop.start() < untag.start() or target_key(stop[1]) != target:
                    continue
                for remove, remove_out in actions[2]:
                    if not stop.end() < remove.start() < untag.start() or target_key(remove[1]) != target:
                        continue
                    if all(
                        not re.search(DOCKER_ERROR, out, FLAGS)
                        and any(target_key(line[1]) == target for line in echoed.finditer(out))
                        for out in (start_out, stop_out, remove_out)
                    ):
                        return True
                    # Pasting multiple commands prints their input lines first,
                    # then three echoes before the image-untagging result.
                    if adjacent(start, stop, text) and adjacent(stop, remove, text) and adjacent(remove, untag, text):
                        if sum(target_key(line[1]) == target for line in echoed.finditer(output[:notice.start()])) == 3:
                            return True
    return False


def nginx_run(name, port, image):
    # Match the name, published port, detached flag and image in the same command.
    # -d and -dit are both valid here; the README command and prose differ.
    # In port numerals only, some terminal OCR reads zero as O or @.
    port = str(port).replace("0", "[0o@]")
    publish = rf"(?:-p|--publish)(?:[ \t]*=[ \t]*|[ \t]+)(?:[0-9.]+{COLON})?{port}{COLON}8[0o@](?:/tcp)?"
    named = rf"--name(?:[ \t]*=[ \t]*|[ \t]+){name}"
    args = rf"(?=[^\n]*[ \t]{DETACHED})(?=[^\n]*[ \t]{publish}[ \t])(?=[^\n]*[ \t]{named}[ \t])"
    return docker_command(rf"run{args}[ \t]+[^\n]{{1,220}}[ \t]+{image}")


START_LATEST = nginx_run(NGINX_NAME, 6001, NGINX_LATEST)
START_OLDER = nginx_run(NGINX_OLDER_NAME, 6002, NGINX_OLDER)
COMMIT = docker_command(rf"commit[ \t]+{NGINX_NAME}[ \t]+nginx{COLON}myimage")


def nginx_started(text, _username):
    # Do not count a pulled layer ID as successful docker run output.
    def distinct(left, right):
        # Repeated OCR may disagree on a few characters of one ID.
        return sum(a != b for a, b in zip(left[:12], right[:12])) >= 4

    def starts(command):
        return [(match, list(returned_ids(output))) for match, output in blocks(command, text, limit=145)
                if not re.search(DOCKER_ERROR, output, FLAGS)]

    for latest, latest_ids in starts(START_LATEST):
        for older, older_ids in starts(START_OLDER):
            if any(distinct(a, b) for a in latest_ids for b in older_ids):
                return True
            if adjacent(latest, older, text) and any(distinct(a, b) for a in older_ids for b in older_ids):
                return True
            if adjacent(older, latest, text) and any(distinct(a, b) for a in latest_ids for b in latest_ids):
                return True
    return False


def commit_returned_id(text, _username):
    return any(
        any(returned_ids(output, digest=True))
        for _, output in blocks(COMMIT, text, limit=14)
        if not re.search(DOCKER_ERROR, output, FLAGS)
    )


def endpoint(port):
    ipv6 = r"\[[0-9a-f:.]+\]"
    host = r"[a-z0-9-]+"
    qualified = rf"(?:{ipv6}|localhost|{host}(?:{DOT}{host})+)"
    with_scheme = rf"https?{COLON}/[ \t]*/[ \t]*(?:{qualified}|{host})"
    return rf"(?<![\w<./-])(?:{with_scheme}|{qualified}){COLON}{port}(?![\d:.])"


LOGS = docker_command(rf"logs[ \t]+{NGINX_NAME}")
ATTACH = docker_command(
    rf"attach[ \t]+(?:(?:--sig-proxy=false|--detach-keys(?:=|[ \t]+)[\"']?(?:ctrl-[a-z0-9]+,)*ctrl-[a-z0-9]+[\"']?)[ \t]+)?{NGINX_NAME}"
)
EXEC = docker_command(rf"exec[ \t]+(?:-it|-ti|-i[ \t]+-t|-t[ \t]+-i|--interactive[ \t]+--tty)[ \t]+{NGINX_NAME}[ \t]+(?:/bin/)?sh")
SHELL_EXIT = terminal(r"exit")
LS_ROOT = terminal(r"(?:ls|1s|l5)[ \t]*/")
PRINTENV = terminal(r"printenv")
ENV_VALUE = r"^[ \t]*(?:HOSTNAME|NGINX_VERSION|PATH|PWD|HOME)[ \t]*=[ \t]*\S+"
SHELL_COMMAND = re.compile(terminal(r"(?:touch|(?:r[mn])|printenv|exit|ls)[ \t]*(?:[ \t][^\n]*)?"), FLAGS)
ROOT_DIRS = {"bin", "boot", "dev", "etc", "home", "lib", "lib64", "media", "mnt",
             "opt", "proc", "root", "run", "sbin", "srv", "sys", "tmp", "usr", "var"}


def root_listing(text, _username):
    for _, output in blocks(LS_ROOT, text, limit=38):
        seen = set()
        for line in output.splitlines():
            if SHELL_COMMAND.fullmatch(line):
                break
            # A bare list of directory names, not paths typed in a later
            # touch/rm command or a variable containing directory paths.
            if re.fullmatch(r"[ \t]*[a-z0-9._-]+(?:[ \t]+[a-z0-9._-]+)*[ \t]*", line, FLAGS):
                seen.update(set(line.casefold().split()) & ROOT_DIRS)
            if len(seen) >= 2 and seen.intersection({"bin", "etc", "usr", "var"}):
                return True
    return False


def returned_to_ubuntu(text, username, command, output_marker):
    for start, output in blocks(command, text, limit=65):
        marker = re.search(output_marker, output, FLAGS)
        if marker is None:
            continue
        next_lines = output[marker.end():].splitlines()
        # Ctrl+P/Ctrl+Q need not print. The request/exit and the later host
        # prompt are observable evidence of returning to the Ubuntu shell.
        for line in next_lines:
            if re.search(r"[@g][ \t]*ubuntu[ \t]*[:$#]", line, FLAGS) and shared.prompt_matches(username, line):
                return True
        end = start.end() + 1 + len(output)
        following = text[end:].lstrip("\n").split("\n", 1)[0]
        if re.search(r"[@g][ \t]*ubuntu[ \t]*[:$#]", following, FLAGS) and shared.prompt_matches(username, following):
            return True
    return False


def check(filename, label, *required, extra=None, forbidden=()):
    return {
        "filename": filename,
        "label": label,
        "required": [{"label": description, "pattern": pattern} for description, pattern in required],
        "forbidden": [{"label": description, "pattern": pattern} for description, pattern in forbidden],
        "extra": extra,
    }


VERSION = rf"v?(?:[0-9]+|s){DOT}[0-9]+(?:{DOT}[0-9]+)?\b"


RUBRIC = [
    check("docker_installation.png", "Check Docker and Docker Compose versions",
          ("docker --version command", terminal(DOCKER + r"(?:--version|-v)\\?")),
          ("Docker version output", rf"Docker[ \t]+version[ \t]+{VERSION}"),
          ("docker compose version command", terminal(DOCKER + r"compose[ \t]+(?:--version|version)")),
          ("Docker Compose version output", rf"Docker[ \t]+Compose[ \t]+version[ \t]+{VERSION}")),
    check("postgres_missing_password.png", "Observe PostgreSQL 9.6 initialization error",
          ("Run postgres:9.6 without setting a password", docker_command(rf"run[ \t]+{POSTGRES_96}")),
          ("PostgreSQL missing-password error",
           r"superuser\s+password\s+(?:is\s+)?not\s+specified|must\s+specify\s+POSTGRES[ _]+PASSWORD\s+to\s+a\s+non[- ]?empty\s+value")),
    check("postgres_96_running.png", "Confirm PostgreSQL 9.6 is running",
          ("docker ps running-container command", PS),
          ("postgres:9.6 row with Up status", result_row(POSTGRES_96, r"Up"))),
    check("postgres_both_versions.png", "Confirm both PostgreSQL versions are running",
          ("docker ps running-container command", PS),
          ("postgres:9.6 row with Up status", result_row(POSTGRES_96, r"Up")),
          ("postgres:10.10 row with Up status", result_row(POSTGRES_1010, r"Up"))),
    check("docker_info.png", "Inspect Docker server information",
          ("docker info command", terminal(DOCKER + r"(?:system[ \t]+)?info")),
          ("Docker server section", r"^[ \t]*Server[ \t]*:"),
          ("Docker server details", r"\b(?:Server\s+Version\s*:\s*v?\d|Containers\s*:\s*\d|Storage\s+Driver\s*:\s*\w)")),
    check("docker_search_ubuntu.png", "Find the official Ubuntu image",
          ("docker search ubuntu command", terminal(DOCKER + r"search[ \t]+ubuntu")),
          ("Official ubuntu result", r"^[ \t]*ubuntu[ \t]+[^\n]{0,220}(?:\[[ \t]*[o0]k[ \t]*\]|Debian[ -]+based[ \t]+Linux)")),
    check("ubuntu_container_status.png", "Compare running and stopped Ubuntu containers",
          ("docker images command", terminal(DOCKER + r"(?:images|image[ \t]+ls)")),
          ("Image listing table", IMAGE_TABLE),
          ("docker run -d ubuntu command", UBUNTU_RUN),
          ("docker ps running-container command", PS),
          ("docker ps -a all-container command", PS_ALL),
          extra=("Matching new Ubuntu container ID absent from docker ps and Exited in docker ps -a", ubuntu_lists)),
    check("postgres_96_cleanup.png", "Restart, stop and remove the PostgreSQL 9.6 container and image",
          ("docker restart command", RESTART),
          ("docker stop command", STOP),
          ("docker rm command", REMOVE),
          ("docker rmi postgres:9.6 command", RMI),
          extra=("Same container returned by restart, stop and rm in order, followed by postgres:9.6 untagging", cleanup_succeeded)),
    check("nginx_containers_started.png", "Start NGINX on host ports 6001 and 6002",
          ("Detached nginx-latest start command on 6001:80", START_LATEST),
          ("Detached nginx-older (1.30.6) start command on 6002:80", START_OLDER),
          extra=("Two distinct returned container IDs", nginx_started)),
    check("nginx_latest_page.png", "Open the NGINX welcome page on port 6001",
          ("Address with port 6001", endpoint(6001)),
          ("Default NGINX welcome page", r"\bWelcome\s+to\s+nginx\b")),
    check("nginx_older_page.png", "Open the NGINX welcome page on port 6002",
          ("Address with port 6002", endpoint(6002)),
          ("Default NGINX welcome page", r"\bWelcome\s+to\s+nginx\b")),
    check("nginx_latest_logs.png", "View NGINX access logs",
          ("docker logs nginx-latest command", LOGS),
          ("Successful HTTP request for the welcome page", HTTP_REQUEST)),
    check("nginx_attach_detach.png", "Attach to NGINX and return to the host",
          ("docker attach nginx-latest command", ATTACH),
          ("Successful HTTP request while attached", HTTP_REQUEST),
          extra=("Registered Ubuntu prompt after the attached request",
                 lambda text, user: returned_to_ubuntu(text, user, ATTACH, HTTP_REQUEST))),
    check("nginx_exec_shell.png", "Change files in the NGINX container shell",
          ("docker exec -it nginx-latest /bin/sh command", EXEC),
          ("ls / command", LS_ROOT),
          ("touch newfile.html in the NGINX document root", terminal(rf"touch[ \t]+[^\n]*{NEWFILE}(?:[ \t]+[^\n]*)?")),
          ("touch oldfile.html in the NGINX document root", terminal(rf"touch[ \t]+[^\n]*{OLDFILE}(?:[ \t]+[^\n]*)?")),
          ("Remove oldfile.html from the NGINX document root", terminal(rf"rm(?:[ \t]+-f)?[ \t]+{OLDFILE}")),
          ("printenv command and environment output", follows(PRINTENV, ENV_VALUE, 3)),
          ("Exit command", SHELL_EXIT),
          extra=("Root directory listing and registered Ubuntu prompt after exit",
                 lambda text, user: root_listing(text, user) and returned_to_ubuntu(text, user, EXEC, SHELL_EXIT))),
    check("nginx_diff.png", "Confirm newfile.html is the remaining file change",
          ("docker diff nginx-latest command", docker_command(rf"diff[ \t]+{NGINX_NAME}")),
          ("Added newfile.html in the Docker diff output", rf"^[ \t]*A[ \t]+{NEWFILE}[ \t]*$"),
          forbidden=(("A remaining oldfile.html change", rf"^[ \t]*[ACD][ \t]+{OLDFILE}[ \t]*$"),)),
    check("nginx_inspect.png", "Inspect the NGINX container's running state",
          ("docker inspect nginx-latest command", docker_command(rf"inspect[ \t]+{NGINX_NAME}")),
          ("Running container state in inspect output", r"[\"']?Running[\"']?[ \t]*:[ \t]*true\b|[\"']?Status[\"']?[ \t]*:[ \t]*[\"']?running\b")),
    check("nginx_commit.png", "Save the modified container as nginx:myimage",
          ("docker commit nginx-latest nginx:myimage command", COMMIT),
          extra=("Returned image ID for the commit", commit_returned_id)),
]
NAMES = [criterion["filename"] for criterion in RUBRIC]
POINT_CHECKS = 17


def normalize_ocr(text):
    text = unicodedata.normalize("NFKC", text).replace("\r\n", "\n").translate(str.maketrans({
        "–": "-", "—": "-", "−": "-", "“": '"', "”": '"', "’": "'",
    }))
    text = re.sub(r"(?<!\S)-[ \t]*(?:-[ \t]*)?"
                  r"(version|all|detach|publish|name|interactive|tty|sig-proxy)(?=[ \t=]|$)",
                  r"--\1", text, flags=FLAGS)
    text = re.sub(r"(\bdocker(?:[ \t]+(?:container|image|system))?)[ \t]*\n(?:[ \t]*\n){0,3}[ \t]*"
                  r"(?=(?:run|ps|images|ls|info|search|restart|stop|rm|rmi|logs|attach|exec|diff|inspect|commit)\b)",
                  r"\1 ", text, flags=FLAGS)
    # Tesseract can put the final image argument on its own line when a long
    # docker run command wraps at the terminal edge.
    text = re.sub(rf"(\bdocker[ \t]+(?:container[ \t]+)?run[ \t]+[^\n]+)\n(?:[ \t]*\n){{0,2}}[ \t]*"
                  rf"({NGINX}(?:{COLON}(?:latest|1{DOT}30{DOT}6))?)[ \t]*$",
                  r"\1 \2", text, flags=FLAGS)
    return re.sub(rf"(\bdocker[ \t]+(?:container[ \t]+)?commit[ \t]+{NGINX_NAME})[ \t]*"
                  rf"\n(?:[ \t]*\n){{0,2}}[ \t|]*(nginx{COLON}myimage)[ \t]*$",
                  r"\1 \2", text, flags=FLAGS)


def grade(submission, total, username):
    if not submission.is_dir():
        return {"score": 0, "feedback": "Required submission directory is missing"}
    submission = submission.resolve()
    directory, directory_problem = shared.screenshot_directory(submission)
    files = dict(shared.resolve(directory, NAMES)) if directory else {}
    peers = shared.peer_screenshots(submission, NAMES)
    points = total / POINT_CHECKS
    passed = review_count = 0
    feedback, review_items = [], []

    try:
        requested_jobs = int(os.environ.get("OCR_JOBS", "4"))
    except ValueError:
        requested_jobs = 4
    workers = max(1, min(requested_jobs, os.cpu_count() or 2, 8))
    with TemporaryDirectory(prefix="devops-lab7-ocr-") as temp, ThreadPoolExecutor(max_workers=workers) as pool:
        pending, early_problems, duplicates = {}, {}, {}
        for name in NAMES:
            path = files.get(name)
            if path == "__AMBIGUOUS__":
                early_problems[name] = "ambiguous filename (multiple case/extension matches)"
            elif not path:
                early_problems[name] = directory_problem or "missing"
            elif not shared.contained_file(image := Path(path), submission):
                early_problems[name] = "image points outside the submission"
            else:
                try:
                    duplicate = shared.duplicate_status(image, peers[name])
                except shared.INVALID_IMAGE_ERRORS:
                    early_problems[name] = "invalid or corrupt image"
                    continue
                if duplicate == "exact":
                    early_problems[name] = "exact duplicate of another student's same task"
                else:
                    duplicates[name] = duplicate
                    pending[name] = pool.submit(shared.run_ocr, image, Path(temp) / (Path(name).stem + ".txt"))

        for index, criterion in enumerate(RUBRIC):
            name = criterion["filename"]
            expected = ["Registered GitHub username@ubuntu prompt"] + [r["label"] for r in criterion["required"]]
            expected.extend("No " + r["label"][0].lower() + r["label"][1:] for r in criterion["forbidden"])
            extra = criterion["extra"]
            if extra:
                expected.append(extra[0])
            if name in early_problems:
                problems = [early_problems[name]]
            else:
                text = normalize_ocr(pending[name].result())
                problems = shared.evidence_problems(criterion, text, username)
                if not problems and extra and not extra[1](text, username):
                    problems.append(extra[0] + " not detected")
            if problems:
                message = ", ".join(problems) + " (0)"
            else:
                passed += 1
                if duplicates[name] == "near":
                    review_count += 1
                    message = "manual review required - visually near-duplicate same-task evidence (provisional credit)"
                else:
                    message = "passed"
            feedback.append(f"{name}: {message}")
            review_items.append({
                "criterion_id": f"devops-lab7-{Path(name).stem}",
                "criterion_order": index,
                "criterion_label": criterion["label"],
                "expected_filename": name,
                "expected_evidence": expected,
                "automatic_points": 0 if problems else float(points),
                "max_points": float(points),
            })

    return {
        "score": float((points * passed).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)),
        "feedback": f"Passed {passed}/{POINT_CHECKS} DevOps Lab 7 checks. " + "; ".join(feedback),
        "review_count": review_count,
        "review_base_points": 0,
        "review_items": review_items,
    }


def main():
    parser = ArgumentParser(prog="test.sh", description="Grade DevOps Lab 07 screenshot evidence.")
    parser.add_argument("submission", type=Path)
    parser.add_argument("total_marks")
    parser.add_argument("github_username", nargs="?")
    args = parser.parse_args()
    try:
        total = Decimal(args.total_marks)
        if not total.is_finite() or total <= 0:
            raise ValueError("TOTAL_MARKS must be a positive finite number")
        if len(NAMES) != POINT_CHECKS or len(set(NAMES)) != POINT_CHECKS:
            raise ValueError("Trusted screenshot count does not match the Lab 07 rubric")
        for tool in ("git", "tesseract"):
            if not shutil.which(tool):
                raise RuntimeError(f"Missing trusted tool: {tool}")
        provided = args.github_username or os.environ.get("STUDENT_GITHUB_USERNAME", "")
        username = shared.normalize_username(provided) if provided else shared.detect_username(args.submission)
        result = grade(args.submission, total, username)
        print(json.dumps(result, ensure_ascii=True, allow_nan=False))
    except Exception as error:
        print(f"DevOps Lab 07 evidence check failed ({type(error).__name__}); no marks were changed.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
