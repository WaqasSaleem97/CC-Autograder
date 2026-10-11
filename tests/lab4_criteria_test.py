#!/usr/bin/env python3

import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
GRADER = ROOT / "tests" / "Lab4" / "test.sh"
SOURCE = GRADER.read_text(encoding="utf-8")


def load_criteria() -> dict[str, tuple[str, list[str]]]:
    match = re.search(
        r"readarray -t criteria <<'EOF'\n(?P<criteria>.*?)\nEOF",
        SOURCE,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Lab 04 criteria block was not found")

    criteria: dict[str, tuple[str, list[str]]] = {}
    for line in match.group("criteria").splitlines():
        filename, identity, expressions = line.split("|", 2)
        criteria[filename] = (identity, expressions.split(";;"))
    return criteria


def load_optional_files() -> set[str]:
    match = re.search(
        r"optional_files=\(\n(?P<files>.*?)\n\)",
        SOURCE,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Lab 04 optional file block was not found")
    return {
        line.strip()
        for line in match.group("files").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


CRITERIA = load_criteria()
OPTIONAL = load_optional_files()


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


class Lab4CriteriaTests(unittest.TestCase):
    def test_required_and_optional_counts_match_the_question(self):
        self.assertEqual(len(CRITERIA), 38)
        self.assertEqual(
            OPTIONAL,
            {
                "vm_login.png",
                "sudo_whoami.png",
                "deluser.png",
            },
        )
        self.assertTrue(OPTIONAL.isdisjoint(CRITERIA))
        self.assertIn("required_screenshots != 38", SOURCE)

    def test_optional_sudo_evidence_cannot_change_the_score(self):
        self.assertNotIn("sudo_whoami.png", CRITERIA)
        self.assertIn('required=$((required_screenshots + 3))', SOURCE)

    def test_screenshot_names_are_resolved_after_normalization(self):
        self.assertIn('canonical_screenshot_name "$filename"', SOURCE)
        self.assertIn('image="$screenshots_dir/$canonical_filename"', SOURCE)
        self.assertIn('canonical_screenshot_name "$optional_file"', SOURCE)

    def test_bonus_and_exam_evidence_are_completely_excluded(self):
        self.assertFalse(any(re.match(r"Q[1-5]_", name) for name in CRITERIA))
        for excluded in (
            "nano_run_demo.png",
            "chmod_run_demo.png",
            "run_demo_output.png",
            "run_demo_output_sudo.png",
            "Q5_user_removed.png",
        ):
            self.assertNotIn(excluded, SOURCE)

    def test_vm_settings_does_not_require_a_brand_label(self):
        valid = """\
Virtual Machine Settings
Memory 4096 MB
Processors 2
Hard Disk 40 GB
Network Adapter NAT
"""
        missing_network = """\
Virtual Machine Settings
Memory 4096 MB
Processors 2
Hard Disk 40 GB
"""
        self.assertTrue(evidence_matches("vm_settings.png", valid))
        self.assertFalse(evidence_matches("vm_settings.png", missing_network))

    def test_copy_verification_requires_both_project_directories(self):
        valid = """\
analyst@ubuntu:~$ ls -la ~/lab4/workspace
python_project
java_app
java_app_copy
"""
        missing_copy = """\
analyst@ubuntu:~$ ls -la ~/lab4/workspace
python_project
java_app
"""
        self.assertTrue(evidence_matches("copy_verify.png", valid))
        self.assertFalse(evidence_matches("copy_verify.png", missing_copy))

    def test_identity_uses_case_insensitive_ocr_tolerance(self):
        self.assertIn('scripts/ocr_evidence.py"', SOURCE)
        self.assertIn('prompt "$normalized_username"', SOURCE)
        self.assertIn("prompt lab4user", SOURCE)

    def test_written_answers_require_more_than_directory_names(self):
        all_directories = """\
/bin contains essential commands.
/usr/bin contains packaged user commands.
/usr/local/bin contains locally installed administrator tools.
"""
        missing_bin = """\
/usr/bin contains packaged user commands.
/usr/local/bin contains locally installed administrator tools.
"""
        self.assertTrue(evidence_matches("answers_md.png", all_directories))
        self.assertFalse(evidence_matches("answers_md.png", missing_bin))
        self.assertIn('minimum_words=20', SOURCE)
        self.assertIn("written explanation is too short", SOURCE)

    def test_current_workspace_and_pdf_requirements_are_enforced(self):
        self.assertIn('project_dir="$workspace_dir/python_project"', SOURCE)
        self.assertIn('copy_dir="$workspace_dir/java_app_copy"', SOURCE)
        self.assertIn('cmp -s "$project_dir/README.md"', SOURCE)
        self.assertIn('solution_pdf="$submission_dir/Lab4_Solution.pdf"', SOURCE)
        self.assertIn('assert source.read(5) == b"%PDF-"', SOURCE)
        self.assertNotIn("word_reports", SOURCE)
        self.assertNotIn("alternate_reports", SOURCE)


if __name__ == "__main__":
    unittest.main()
