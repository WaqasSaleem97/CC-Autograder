#!/usr/bin/env python3

import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GRADER = ROOT / "tests" / "Lab2" / "test.sh"


def load_criteria() -> dict[str, list[str]]:
    source = GRADER.read_text(encoding="utf-8")
    match = re.search(
        r"readarray -t criteria <<'EOF'\n(?P<criteria>.*?)\nEOF",
        source,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Lab 2 criteria block was not found")

    criteria: dict[str, list[str]] = {}
    for line in match.group("criteria").splitlines():
        filename, expressions = line.split("|", 1)
        criteria[filename] = expressions.split(";;")
    return criteria


CRITERIA = load_criteria()


def evidence_matches(filename: str, text: str) -> bool:
    return all(
        subprocess.run(
            ["grep", "-Eiq", "--", expression],
            input=text,
            text=True,
            check=False,
        ).returncode
        == 0
        for expression in CRITERIA[filename]
    )


class Lab2CriteriaTests(unittest.TestCase):
    def test_required_file_count_stays_at_37(self):
        self.assertEqual(len(CRITERIA), 37)

    def test_private_repository_requires_the_assigned_repository_name(self):
        self.assertTrue(
            evidence_matches(
                "repo_private.png",
                "WaqasSaleem97 / CC_Lab2_Practice   Private",
            )
        )
        self.assertTrue(
            evidence_matches(
                "repo_private.png",
                "CC Lab 02 Practice — PRIVATE repository",
            )
        )
        self.assertFalse(
            evidence_matches(
                "repo_private.png",
                "WaqasSaleem97 / unrelated-project   Private repository",
            )
        )

    def test_git_identity_requires_both_name_and_email(self):
        complete = """\
git config --global user.name \"Student Name\"
git config --global user.email student@example.com
"""
        for filename in ("git_identity.png", "git_config_list.png"):
            with self.subTest(filename=filename):
                self.assertTrue(evidence_matches(filename, complete))
                self.assertFalse(
                    evidence_matches(
                        filename,
                        "git config --global user.name \"Student Name\"",
                    )
                )

    def test_delete_git_requires_the_follow_up_status_error(self):
        complete = """\
student@ubuntu:~/CC_Lab2_Practice$ rm -rf .git
student@ubuntu:~/CC_Lab2_Practice$ git status
fatal: not a git repository (or any of the parent directories): .git
"""
        self.assertTrue(evidence_matches("delete_git.png", complete))
        self.assertFalse(
            evidence_matches("delete_git.png", "rm -rf .git")
        )

    def test_feature_branch_requires_creation_and_push(self):
        complete = """\
git checkout -b feature/db-connection
Switched to a new branch 'feature/db-connection'
git push origin feature/db-connection
"""
        switch_variant = """\
git switch -c feature/db-connection
git push origin feature/db-connection
"""
        self.assertTrue(evidence_matches("feature_db_branch.png", complete))
        self.assertTrue(
            evidence_matches("feature_db_branch.png", switch_variant)
        )
        self.assertFalse(
            evidence_matches(
                "feature_db_branch.png",
                "git push origin feature/db-connection",
            )
        )

    def test_pull_request_details_do_not_depend_on_ui_labels(self):
        valid_form = """\
Open a pull request
base: main  compare: feature/refactor
Improve database connection handling
Adds retry logic and clearer errors.
"""
        self.assertTrue(
            evidence_matches("pr_create_details.png", valid_form)
        )
        self.assertFalse(
            evidence_matches(
                "pr_create_details.png",
                "Open a pull request from feature/refactor to develop",
            )
        )

    def test_remote_delete_command_does_not_require_literal_branch_word(self):
        valid_command = """\
student@ubuntu:~/CC_Lab2_Practice$ git push origin --delete feature/login
To github.com:student/CC_Lab2_Practice.git
 - [deleted] feature/login
"""
        self.assertTrue(
            evidence_matches("remote_branch_delete_cmd.png", valid_command)
        )
        self.assertFalse(
            evidence_matches(
                "remote_branch_delete_cmd.png",
                "git push origin feature/login",
            )
        )


if __name__ == "__main__":
    unittest.main()
