#!/usr/bin/env python3

import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GRADER = ROOT / "tests" / "Assignment01" / "test.sh"


def load_criteria() -> dict[str, tuple[str, list[str]]]:
    source = GRADER.read_text(encoding="utf-8")
    match = re.search(
        r"readarray -t criteria <<'EOF'\n(?P<criteria>.*?)\nEOF",
        source,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Assignment 01 criteria block was not found")

    criteria: dict[str, tuple[str, list[str]]] = {}
    for line in match.group("criteria").splitlines():
        filename, identity, expressions = line.split("|", 2)
        criteria[filename] = (identity, expressions.split(";;"))
    return criteria


CRITERIA = load_criteria()


def evidence_matches(filename: str, text: str) -> bool:
    _identity, expressions = CRITERIA[filename]
    return all(
        subprocess.run(
            ["grep", "-Eiq", "--", expression],
            input=text,
            text=True,
            check=False,
        ).returncode
        == 0
        for expression in expressions
    )


class Assignment1CriteriaTests(unittest.TestCase):
    def test_required_screenshot_count_stays_at_12(self):
        self.assertEqual(len(CRITERIA), 12)

    def test_all_terminal_screenshots_require_the_ubuntu_identity(self):
        terminal_files = {
            "task1_gitea_running.png",
            "task1_gitea_push.png",
            "task2_remotes.png",
            "task2_github_push.png",
            "task3_lfs_setup.png",
            "task3_lfs_files.png",
            "task3_lfs_push.png",
        }
        for filename in terminal_files:
            with self.subTest(filename=filename):
                self.assertEqual(CRITERIA[filename][0], "ubuntu")
        self.assertNotIn(
            "codespace",
            {identity for identity, _expressions in CRITERIA.values()},
        )

    def test_gitea_running_requires_ubuntu_compose_and_http_evidence(self):
        valid = """\
student@ubuntu:~/Gitea$ docker compose ps
NAME       IMAGE                       STATUS
gitea      gitea/gitea:latest          Up 20 seconds
gitea_db   postgres:17-alpine          Up 25 seconds (healthy)
student@ubuntu:~/Gitea$ curl http://127.0.0.1:3000/
Gitea HTTP status: 200
"""
        old_codespaces_page = """\
Gitea Sign In
https://example-3000.app.github.dev
Repositories
"""
        self.assertTrue(evidence_matches("task1_gitea_running.png", valid))
        self.assertFalse(
            evidence_matches("task1_gitea_running.png", old_codespaces_page)
        )

    def test_gitea_push_requires_push_not_pull(self):
        valid = """\
student@ubuntu:~/Assignment01$ git push -u gitea main
To http://127.0.0.1:3000/student/Assignment01.git
 * [new branch] main -> main
branch 'main' set up to track 'gitea/main'
"""
        pull_only = """\
student@ubuntu:~/Assignment01$ git pull gitea main
Already up to date.
"""
        self.assertTrue(evidence_matches("task1_gitea_push.png", valid))
        self.assertFalse(evidence_matches("task1_gitea_push.png", pull_only))

    def test_remote_evidence_requires_local_gitea_and_github(self):
        valid = """\
student@ubuntu:~/Assignment01$ git remote -v
gitea http://student@127.0.0.1:3000/student/Assignment01.git (fetch)
gitea http://student@127.0.0.1:3000/student/Assignment01.git (push)
github https://github.com/student/Assignment01.git (fetch)
github https://github.com/student/Assignment01.git (push)
"""
        github_only = """\
student@ubuntu:~/Assignment01$ git remote -v
github https://github.com/student/Assignment01.git (fetch)
github https://github.com/student/Assignment01.git (push)
"""
        self.assertTrue(evidence_matches("task2_remotes.png", valid))
        self.assertFalse(evidence_matches("task2_remotes.png", github_only))

    def test_lfs_setup_requires_install_version_tracking_and_attributes(self):
        valid = """\
git lfs install
Git LFS initialized.
git lfs version
git-lfs/3.7.0
git lfs track "*.bin"
cat .gitattributes
*.bin filter=lfs diff=lfs merge=lfs -text
"""
        missing_install = """\
git lfs version
git-lfs/3.7.0
git lfs track "*.bin"
cat .gitattributes
*.bin filter=lfs diff=lfs merge=lfs -text
"""
        self.assertTrue(evidence_matches("task3_lfs_setup.png", valid))
        self.assertFalse(
            evidence_matches("task3_lfs_setup.png", missing_install)
        )

    def test_pages_repository_requires_both_source_files_and_public_status(self):
        valid = """\
student.github.io
Public
index.html
styles.css
"""
        missing_styles = """\
student.github.io
Public
index.html
portfolio
"""
        self.assertTrue(
            evidence_matches("task4_pages_repository.png", valid)
        )
        self.assertFalse(
            evidence_matches("task4_pages_repository.png", missing_styles)
        )

    def test_required_files_and_weighted_scoring_remain_enabled(self):
        source = GRADER.read_text(encoding="utf-8")
        for filename in (
            "Assignment01.md",
            "Assignment01_Solution.docx",
            "Assignment01_Solution.pdf",
        ):
            self.assertIn(filename, source)
        self.assertIn('Decimal("0.90")', source)
        self.assertIn('Decimal("0.10")', source)
        self.assertIn("lfs_size_count", source)
        self.assertIn("sizes above 100 MiB", source)


if __name__ == "__main__":
    unittest.main()
