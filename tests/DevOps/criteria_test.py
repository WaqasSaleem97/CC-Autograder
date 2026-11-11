#!/usr/bin/env python3
"""Offline regression checks for the published DevOps Lab05/Lab06 evidence."""

from collections import Counter
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evidence_grader as grader

HERE = Path(__file__).resolve().parent
RUBRICS = {lab: grader.load_rubric(HERE / f"Lab{lab}/criteria.json") for lab in (5, 6)}
SAMPLES = {lab: json.loads((HERE / f"fixtures/lab{lab}-ocr.json").read_text()) for lab in (5, 6)}
CHECKS = {lab: {c["filename"]: c for c in r["screenshots"]} for lab, r in RUBRICS.items()}

EXPECTED = {
    5: """intellij_repo_clone intellij_running intellij_desktop maven_project_clone
        maven_installed maven_package maven_elasticsearch_dependency maven_repackage
        maven_test maven_jar maven_running maven_stopped maven_project_closed
        gradle_project_clone gradle_build gradle_elasticsearch_dependency
        gradle_rebuild gradle_jar gradle_running gradle_stopped gradle_project_closed
        node_project_clone nodejs_installed npm_install node_running node_browser
        npm_test npm_pack react_node_project_clone react_api_dependencies
        react_api_build react_api_bundle docker_installed dockerfile_exists
        docker_images_before docker_build docker_images_after""",
    6: """nexus_container_running nexus_user_access gradle_nexus_configuration
        gradle_nexus_build gradle_nexus_publish nexus_gradle_artifact
        maven_nexus_project maven_distribution_management maven_package_nexus
        maven_deploy_nexus nexus_maven_artifact nexus_repositories_user
        nexus_repositories_admin nexus_components_list nexus_component_details
        nexus_default_blob_content nexus_mystore_created nexus_blob_directories
        nexus_docker_hosted_repository nexus_cleanup_policy_created
        nexus_cleanup_policy_attached nexus_cleanup_task_waiting
        nexus_cleanup_task_completed nexus_maven_snapshots_empty
        nexus_blob_store_before_compaction nexus_compact_task_configured
        nexus_compact_task_completed nexus_blob_store_after_compaction""",
}


class CriteriaTests(unittest.TestCase):
    def problems(self, lab, filename, text):
        return grader.evidence_problems(CHECKS[lab][filename], text, "student-name")

    def test_exact_published_screenshot_sets(self):
        for lab in (5, 6):
            self.assertEqual(list(CHECKS[lab]), [name + ".png" for name in EXPECTED[lab].split()])
            self.assertEqual(set(SAMPLES[lab]), set(CHECKS[lab]))
            self.assertEqual(RUBRICS[lab]["solution_pdf"], f"Lab{lab}_Solution.pdf")
            self.assertIn(f"Labs/Lab0{lab}/README.md", RUBRICS[lab]["source_url"])
            self.assertRegex(RUBRICS[lab]["source_commit"], r"^[0-9a-f]{40}$")

    def test_published_task_counts(self):
        self.assertEqual(Counter(c["task"] for c in CHECKS[5].values()), {1: 3, 2: 10, 3: 8, 4: 7, 5: 4, 6: 5})
        self.assertEqual(Counter(c["task"] for c in CHECKS[6].values()), {1: 1, 2: 1, 3: 4, 4: 5, 5: 4, 6: 4, 7: 9})

    def test_all_65_valid_ocr_examples_pass(self):
        for lab, samples in SAMPLES.items():
            for filename, text in samples.items():
                with self.subTest(lab=lab, filename=filename):
                    self.assertEqual(self.problems(lab, filename, text), [])

    def test_every_criterion_rejects_unrelated_work(self):
        for lab, checks in CHECKS.items():
            for filename in checks:
                with self.subTest(lab=lab, filename=filename):
                    self.assertTrue(self.problems(lab, filename, "student-name@ubuntu:~$ echo hello\nhello"))

    def test_every_criterion_requires_the_registered_identity(self):
        for lab, samples in SAMPLES.items():
            for filename, text in samples.items():
                with self.subTest(lab=lab, filename=filename):
                    self.assertIn("registered GitHub username@ubuntu prompt not detected", self.problems(lab, filename, text.replace("Student-Name", "Different-User")))
                    self.assertEqual(self.problems(lab, filename, text.replace("Student-Name", "STUDENT-NAME")), [])

    def test_command_without_result_is_not_enough(self):
        commands = {
            (5, "maven_package.png"): "mvn package",
            (5, "gradle_build.png"): "./gradlew build",
            (5, "npm_test.png"): "npm test",
            (5, "docker_build.png"): "docker build -t lab5:1.0 .",
            (6, "nexus_user_access.png"): "curl -i -u nexus http://10.0.0.5:8006/service/rest/v1/status",
            (6, "maven_deploy_nexus.png"): "mvn deploy",
        }
        for (lab, filename), command in commands.items():
            self.assertTrue(self.problems(lab, filename, "student-name@ubuntu:~$ " + command))

    def test_failed_build_and_tests_do_not_pass(self):
        replacements = [
            (5, "maven_package.png", "BUILD SUCCESS", "BUILD FAILURE"),
            (5, "gradle_build.png", "BUILD SUCCESSFUL", "BUILD FAILED"),
            (6, "gradle_nexus_publish.png", "BUILD SUCCESSFUL", "BUILD FAILED"),
            (6, "maven_deploy_nexus.png", "BUILD SUCCESS", "BUILD FAILURE"),
        ]
        for lab, filename, good, bad in replacements:
            self.assertTrue(self.problems(lab, filename, SAMPLES[lab][filename].replace(good, bad)))
        self.assertTrue(self.problems(5, "npm_test.png", "student-name@ubuntu:~$ npm test\nFAIL index.test.js\n1 failed"))

    def test_maven_no_tests_to_run_is_valid(self):
        self.assertEqual(self.problems(5, "maven_test.png", SAMPLES[5]["maven_test.png"]), [])

    def test_docker_legacy_and_buildkit_results_are_accepted(self):
        buildkit = SAMPLES[5]["docker_build.png"]
        legacy = buildkit.replace("#10 naming to docker.io/library/lab5:1.0 done", "Successfully tagged lab5:1.0")
        self.assertEqual(self.problems(5, "docker_build.png", legacy), [])
        self.assertTrue(self.problems(5, "docker_build.png", buildkit.replace("lab5:1.0", "lab5:2.0")))

    def test_docker_current_and_classic_image_lists(self):
        command = "student-name@ubuntu:~$ sudo docker images"
        current = command + "\nIMAGE IMAGE ID DISK USAGE CONTENT SIZE EXTRA"
        self.assertEqual(self.problems(5, "docker_images_before.png", current), [])
        for row in ("lab5:1.0 abc123def456 418MB 86MB", "docker.io/library/lab5:1.0\nabc123def456"):
            self.assertEqual(self.problems(5, "docker_images_after.png", current + "\n" + row), [])
        classic = command + "\nREPOSITORY TAG IMAGE ID CREATED SIZE\nlab5 1.0 abc123def456"
        self.assertEqual(self.problems(5, "docker_images_after.png", classic), [])
        for row in ("lab5:1.0", "lab5:2.0 abc123def456", "other:1.0 abc123def456", "lab5:1.0.1 abc123def456"):
            self.assertTrue(self.problems(5, "docker_images_after.png", current + "\n" + row))
        self.assertTrue(self.problems(5, "docker_images_after.png", current + "\nstudent-name@ubuntu:~$ docker build -t lab5:1.0 ."))
        self.assertTrue(self.problems(5, "docker_images_before.png", command))

    def test_docker_build_ocr_spacing_still_requires_correct_context_and_tag(self):
        buildkit = SAMPLES[5]["docker_build.png"]
        for noisy_command in ("lab5:1.0.", "1ab5:1.0 ."):
            self.assertEqual(self.problems(5, "docker_build.png", buildkit.replace("lab5:1.0 .", noisy_command)), [])
        self.assertTrue(self.problems(5, "docker_build.png", buildkit.replace("lab5:1.0 .", "lab5:1.0 .wrong-context")))
        self.assertTrue(self.problems(5, "docker_build.png", buildkit.replace("naming to docker.io/library/lab5:1.0 done", "naming to docker.io/library/1ab5:1.0 done")))

    def test_dockerfile_evidence_checks_listing_not_unrequested_app_folder(self):
        evidence = "student-name@ubuntu:~/node-project$ 1s\nDockerfile Jenkinsfile README.md"
        self.assertEqual(self.problems(5, "dockerfile_exists.png", evidence), [])
        self.assertEqual(self.problems(5, "dockerfile_exists.png", "student-name@ubuntu:~$ ls -l Dockerfile\n-rw-r--r-- 1 user user 350 Nov 6 Dockerfile"), [])
        self.assertTrue(self.problems(5, "dockerfile_exists.png", "student-name@ubuntu:~$ ls Dockerfile"))

    def test_intellij_welcome_does_not_require_address_bar(self):
        evidence = "Welcome to IntelliJ IDEA\nNew Project Open Clone Repository\nstudent-name@ubuntu:~$"
        self.assertEqual(self.problems(5, "intellij_desktop.png", evidence), [])
        self.assertTrue(self.problems(5, "intellij_desktop.png", evidence.replace("student-name", "different-user")))

    def test_maven_success_without_required_command_is_not_enough(self):
        evidence = "student-name@ubuntu:~$\n[INFO] Building jar: target/java-maven-app.jar\n[INFO] BUILD SUCCESS"
        self.assertTrue(self.problems(5, "maven_package.png", evidence))
        self.assertTrue(self.problems(5, "maven_repackage.png", evidence))

    def test_wrong_dependency_version_and_node_port_are_rejected(self):
        for filename in ("maven_elasticsearch_dependency.png", "gradle_elasticsearch_dependency.png"):
            self.assertTrue(self.problems(5, filename, SAMPLES[5][filename].replace("7.0.0", "8.0.0")))
        for filename in ("node_running.png", "node_browser.png"):
            self.assertTrue(self.problems(5, filename, SAMPLES[5][filename].replace("4000", "3000")))

    def test_nexus_connector_must_be_8007_not_the_old_8087(self):
        text = SAMPLES[6]["nexus_docker_hosted_repository.png"]
        self.assertTrue(self.problems(6, "nexus_docker_hosted_repository.png", text.replace("8007", "8087")))

    def test_task6_does_not_require_second_docker_exec(self):
        self.assertNotIn("docker exec", SAMPLES[6]["nexus_blob_directories.png"])
        self.assertEqual(self.problems(6, "nexus_blob_directories.png", SAMPLES[6]["nexus_blob_directories.png"]), [])

    def test_lab6_reuses_maven_project_instead_of_requiring_clone(self):
        self.assertNotIn("git clone", SAMPLES[6]["maven_nexus_project.png"])
        self.assertEqual(self.problems(6, "maven_nexus_project.png", SAMPLES[6]["maven_nexus_project.png"]), [])

    def test_timestamped_or_literal_snapshot_artifacts_pass(self):
        for filename in ("nexus_gradle_artifact.png", "nexus_maven_artifact.png"):
            text = SAMPLES[6][filename]
            literal = text.replace("20261106.090000-1", "SNAPSHOT")
            self.assertEqual(self.problems(6, filename, text), [])
            self.assertEqual(self.problems(6, filename, literal), [])
            self.assertTrue(self.problems(6, filename, text.replace(".jar", ".txt")))

    def test_publish_to_maven_local_is_not_nexus_publication(self):
        filename = "gradle_nexus_publish.png"
        self.assertTrue(self.problems(6, filename, SAMPLES[6][filename].replace("publishMavenPublicationToNexusRepository", "publishToMavenLocal")))

    def test_api_account_and_actual_component_id_are_checked(self):
        for filename, account in (("nexus_repositories_user.png", "nexus"), ("nexus_repositories_admin.png", "admin")):
            self.assertTrue(self.problems(6, filename, SAMPLES[6][filename].replace("-u " + account, "-u wrong")))
        filename = "nexus_component_details.png"
        self.assertTrue(self.problems(6, filename, SAMPLES[6][filename].replace("bWF2ZW46YWJjZA", "<component-id>")))
        self.assertTrue(self.problems(6, filename, SAMPLES[6][filename].replace("/components/bWF2ZW46YWJjZA", "/components?repository=maven-snapshots")))

    def test_restricted_user_can_see_empty_repository_list(self):
        text = 'student-name@ubuntu:~$ curl -u nexus "http://10.0.0.5:8006/service/rest/v1/repositories"\n[]'
        self.assertEqual(self.problems(6, "nexus_repositories_user.png", text), [])

    def test_cleanup_and_compaction_are_not_confused(self):
        self.assertTrue(self.problems(6, "nexus_compact_task_completed.png", SAMPLES[6]["nexus_cleanup_task_completed.png"]))
        self.assertTrue(self.problems(6, "nexus_cleanup_task_completed.png", SAMPLES[6]["nexus_compact_task_completed.png"]))
        for filename in ("nexus_cleanup_task_completed.png", "nexus_compact_task_completed.png"):
            self.assertTrue(self.problems(6, filename, SAMPLES[6][filename].replace("Last result Ok", "Last result Error")))

    def test_schedule_values_but_not_instructor_dates_are_checked(self):
        for filename, good_time, bad_time in (("nexus_cleanup_task_waiting.png", "06:00", "07:00"), ("nexus_compact_task_configured.png", "06:30", "08:00")):
            text = SAMPLES[6][filename]
            self.assertEqual(self.problems(6, filename, text.replace("Nov 06 2026", "Dec 20 2027")), [])
            self.assertTrue(self.problems(6, filename, text.replace(good_time, bad_time)))

    def test_storage_sizes_and_ip_addresses_are_not_hard_coded(self):
        for filename in ("nexus_blob_store_before_compaction.png", "nexus_blob_store_after_compaction.png"):
            text = "student-name@ubuntu:~$\nBlob Stores\nName Blob Count Used Size Available Space\ndefault 90 20.4 MiB 30.9 GiB"
            self.assertEqual(self.problems(6, filename, text), [])
        for filename in ("nexus_user_access.png", "nexus_components_list.png"):
            self.assertEqual(self.problems(6, filename, SAMPLES[6][filename].replace("10.0.0.5", "192.168.1.200")), [])

    def test_no_removed_or_unrequired_screenshots_are_graded(self):
        removed = {"nexus_login_page.png", "nexus_setup_complete.png", "nexus_role_created.png", "nexus_role_privilege.png", "nexus_user_created.png", "gradle_jdk_configured.png", "gradle_nexus_project.png"}
        self.assertTrue(removed.isdisjoint(CHECKS[6]))
        self.assertFalse(any("exam" in name for checks in CHECKS.values() for name in checks))

    def test_trusted_nexus_reference_hashes_are_pinned(self):
        hashes = RUBRICS[6]["instructor_reference_git_blobs"]
        self.assertEqual(len(hashes), 37)
        self.assertTrue(all(__import__("re").fullmatch(r"[0-9a-f]{40}", value) for value in hashes))


if __name__ == "__main__":
    unittest.main()
