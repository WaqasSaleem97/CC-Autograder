#!/usr/bin/env python3

import collections
import pathlib
import re
import subprocess
import unittest


GRADER = pathlib.Path(__file__).with_name("test.sh")
SOURCE = GRADER.read_text(encoding="utf-8")


def load_criteria() -> dict[str, tuple[str, list[str]]]:
    match = re.search(
        r"readarray -t criteria <<'EOF'\n(?P<criteria>.*?)\nEOF",
        SOURCE,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Lab 05 criteria block was not found")

    criteria: dict[str, tuple[str, list[str]]] = {}
    for line in match.group("criteria").splitlines():
        filename_spec, identity, expressions = line.split("|", 2)
        criteria[filename_spec] = (identity, expressions.split(";;"))
    return criteria


def load_optional_files() -> set[str]:
    match = re.search(
        r"optional_files=\(\n(?P<files>.*?)\n\)",
        SOURCE,
        flags=re.DOTALL,
    )
    if match is None:
        raise AssertionError("Lab 05 optional file block was not found")
    return {
        line.strip()
        for line in match.group("files").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


CRITERIA = load_criteria()
OPTIONAL = load_optional_files()


def evidence_matches(filename_spec: str, text: str) -> bool:
    _identity, expressions = CRITERIA[filename_spec]
    for expression in expressions:
        forbidden = expression.startswith("!")
        pattern = expression[1:] if forbidden else expression
        matched = (
            subprocess.run(
                ["grep", "-Eiq", "--", pattern],
                input=text,
                text=True,
                check=False,
            ).returncode
            == 0
        )
        if matched == forbidden:
            return False
    return True


class Lab5CriteriaTests(unittest.TestCase):
    def test_exact_core_counts_match_the_published_tasks(self):
        self.assertEqual(len(CRITERIA), 69)
        counts = collections.Counter()
        for filename_spec in CRITERIA:
            primary = filename_spec.split(",", 1)[0]
            match = re.match(r"task([0-9]+)_", primary)
            self.assertIsNotNone(match, primary)
            counts[int(match.group(1))] += 1

        self.assertEqual(
            counts,
            {
                1: 6,
                2: 4,
                3: 3,
                4: 4,
                5: 7,
                6: 11,
                7: 9,
                8: 8,
                9: 4,
                10: 3,
                11: 4,
                12: 6,
            },
        )
        self.assertIn("required_screenshots != 69", SOURCE)
        self.assertIn("required != 71", SOURCE)

    def test_only_conditional_vim_install_is_unscored(self):
        self.assertEqual(OPTIONAL, {"task9_vim_install.png"})
        self.assertTrue(
            all(
                "task9_vim_install.png" not in filename_spec
                for filename_spec in CRITERIA
            )
        )

    def test_exam_and_removed_legacy_evidence_are_absent(self):
        lowered = SOURCE.casefold()
        self.assertNotIn("exam_", lowered)
        self.assertNotIn("docker_desktop", lowered)
        for removed in (
            "task6_gui_start_command.png",
            "task7_ls_etc_apt.png",
            "task7_cat_sources_list.png",
            "task7_cat_ubuntu_sources.png",
            "task7_edit_ubuntu_sources.png",
            "task7_alternate_remove.png",
            "task7_alternate_edit.png",
            "task7_remove_key.png",
            "task7_add_key_alt.png",
            "task7_apt_update_alt.png",
            "task7_install_chrome_alt.png",
        ):
            self.assertNotIn(removed, SOURCE)

    def test_case_extensions_and_alternative_names_are_resolved(self):
        self.assertIn("scripts/resolve_screenshots.py", SOURCE)
        self.assertIn("repeated extensions such as .png.png", SOURCE)
        self.assertIn(
            "task8_audacity_launch.png,task8_audacity_version.png",
            CRITERIA,
        )
        self.assertIn(
            "task8_obs_launch.png,task8_obs_version.png",
            CRITERIA,
        )

    def test_identity_uses_case_insensitive_ocr_helper(self):
        self.assertIn('prompt "$normalized_username"', SOURCE)
        self.assertIn("scripts/ocr_evidence.py", SOURCE)

    def test_updated_command_evidence_matches_the_question(self):
        self.assertTrue(
            evidence_matches(
                "task4_snap_bin_location.png",
                "student@ubuntu:~$ ls -l /snap/bin/code\n"
                "lrwxrwxrwx code -> /usr/bin/snap",
            )
        )
        self.assertTrue(
            evidence_matches(
                "task6_lightdm_cleanup.png",
                "student@ubuntu:~$ rm -f ~/.Xauthority\n"
                "student@ubuntu:~$ rm -rf ~/.cache/sessions",
            )
        )
        self.assertTrue(
            evidence_matches(
                "task9_k8s_saved.png",
                "student@ubuntu:~/Lab5$ ls -l k8s-sample.yaml\n"
                "apiVersion: v1\nkind: Pod",
            )
        )
        self.assertTrue(
            evidence_matches(
                "task6_gui_start.png",
                "systemctl is-active lightdm\nactive",
            )
        )
        self.assertFalse(
            evidence_matches(
                "task6_gui_start.png",
                "systemctl is-active lightdm\ninactive",
            )
        )

    def test_chrome_criteria_use_the_single_signed_https_flow(self):
        self.assertIn("task7_prerequisites.png", CRITERIA)
        self.assertIn("task7_verify_source.png", CRITERIA)
        self.assertIn("task7_chrome_version.png", CRITERIA)
        valid = (
            "student@ubuntu:~$ cat /etc/apt/sources.list.d/google-chrome.list\n"
            "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] "
            "https://dl.google.com/linux/chrome/deb/ stable main"
        )
        self.assertTrue(evidence_matches("task7_verify_source.png", valid))

    def test_forbidden_temporary_and_substituted_text_is_rejected(self):
        clean = (
            "cat k8s-sample.yaml\n"
            "metadata:\n  name: nginx-pod\n  annotations:\n    lab: lesson11"
        )
        dirty = clean + "\n# temp: do-not-keep"
        self.assertTrue(evidence_matches("task10_verify_no_temp_comment.png", clean))
        self.assertFalse(evidence_matches("task10_verify_no_temp_comment.png", dirty))
        self.assertTrue(
            evidence_matches(
                "task12_substitute_result.png",
                "name: webapp-pod\nimage: webapp:1.19",
            )
        )
        self.assertFalse(
            evidence_matches(
                "task12_substitute_result.png",
                "name: webapp-pod\nimage: nginx:1.19",
            )
        )

    def test_manifest_and_exact_pdf_are_scored(self):
        self.assertIn('manifest="$submission_dir/workspace/k8s-sample.yaml"', SOURCE)
        self.assertIn("exactly one top-level spec section", SOURCE)
        self.assertIn("lab:\\s*lesson11", SOURCE)
        self.assertIn('solution_pdf="$submission_dir/Lab5_Solution.pdf"', SOURCE)
        self.assertIn('assert source.read(5) == b"%PDF-"', SOURCE)
        self.assertIn('required=$((required_screenshots + 2))', SOURCE)


if __name__ == "__main__":
    unittest.main()

