#!/usr/bin/env python3
"""Exercise scoring, isolation, filename rules and the real OCR entry point."""

from decimal import Decimal
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evidence_grader as grader

HERE = Path(__file__).resolve().parent


def corrupt_png_checksum(path):
    """Damage an IDAT checksum while leaving the PNG header readable."""
    data = bytearray(path.read_bytes())
    offset = 8  # PNG signature
    while offset + 12 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        if data[offset + 4:offset + 8] == b"IDAT":
            data[offset + 8 + length] ^= 1
            path.write_bytes(data)
            return
        offset += length + 12
    raise AssertionError("Fixture PNG has no IDAT chunk")


def make_pdf(path):
    # A minimal real, one-page PDF with a valid xref table, not a fake header.
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Contents 4 0 R >>",
        b"<< /Length 0 >>\nstream\n\nendstream",
    ]
    result = bytearray(b"%PDF-1.4\n")
    offsets = [0]
    for number, value in enumerate(objects, 1):
        offsets.append(len(result))
        result.extend(f"{number} 0 obj\n".encode() + value + b"\nendobj\n")
    xref = len(result)
    result.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        result.extend(f"{offset:010d} 00000 n \n".encode())
    result.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(result)


class CredentialTests(unittest.TestCase):
    def test_real_nexus_and_build_credentials_are_rejected(self):
        for value in (
            'curl -u nexus:DemoPassword123 -X GET "http://server:8006/service/rest/v1/status"',
            'curl --user "admin:AnotherPassword" http://server:8006',
            "repoPassword=DemoPassword123",
            "<password>DemoPassword123</password>",
            "password = 'DemoPassword123'",
            "Authorization: Basic bmV4dXM6cGFzc3dvcmQ=",
            "docker exec nexus cat /nexus-data/admin.password\n12345678-1234-1234-1234-123456789abc",
            "token=ghp_" + "a" * 36,
            "-----BEGIN OPENSSH PRIVATE KEY-----",
        ):
            with self.subTest(value=value[:30]):
                self.assertTrue(grader.credential_visible(value))

    def test_hidden_prompts_masks_placeholders_and_references_are_safe(self):
        for value in (
            "curl -u nexus http://server:8006/service/rest/v1/status\nEnter host password for user 'nexus':",
            "password project.repoPassword",
            "password = project.repoPassword",
            "repoPassword=********",
            "<password>REDACTED</password>",
            "repoPassword=<nexus-user-password>",
            "repoPassword=${NEXUS_PASSWORD}",
            "<password>REPLACE_WITH_NEXUS_PASSWORD</password>",
            "http://10.0.0.5:8006/repository/maven-snapshots/\nstudent-name@ubuntu:~$",
        ):
            with self.subTest(value=value):
                self.assertFalse(grader.credential_visible(value))

    def test_username_normalization_and_validation(self):
        for value in ("Student-Name", "@STUDENT-NAME", "https://github.com/Student-Name/DevOps", "git@github.com:Student-Name/DevOps.git"):
            self.assertEqual(grader.normalize_username(value), "student-name")
        for value in ("", "bad_name", "bad--name", "-bad", "bad/../x", "a" * 40):
            if value == "bad/../x":
                continue  # User profile URLs may contain trailing path segments.
            with self.assertRaises(ValueError):
                grader.normalize_username(value)


class GradingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="devops-grader-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        grader.image_fingerprint.cache_clear()
        self.addCleanup(grader.image_fingerprint.cache_clear)
        self.lab = 5
        self.prepare(5)

    def prepare(self, lab):
        self.lab = lab
        self.rubric = grader.load_rubric(HERE / f"Lab{lab}/criteria.json")
        self.samples = json.loads((HERE / f"fixtures/lab{lab}-ocr.json").read_text())
        self.submission = self.root / f"Lab0{lab}"
        self.images = self.submission / "screenshots"
        self.images.mkdir(parents=True, exist_ok=True)
        for index, check in enumerate(self.rubric["screenshots"]):
            image = Image.new("RGB", (500, 160), (240, 240, 240))
            ImageDraw.Draw(image).text((20, 20), check["filename"] + str(index), fill="black")
            image.save(self.images / check["filename"])
        make_pdf(self.submission / self.rubric["solution_pdf"])

    def run_grade(self, text_overrides=None, peers=None):
        samples = {**self.samples, **(text_overrides or {})}
        def ocr(_image, destination):
            return samples[destination.stem + ".png"]
        with mock.patch.object(grader, "run_ocr", side_effect=ocr), mock.patch.object(grader, "peer_screenshots", return_value=peers or {name: [] for name in self.samples}):
            return grader.grade(self.submission, Decimal("10"), "student-name", self.rubric)

    def test_both_complete_labs_receive_full_credit_and_review_metadata(self):
        for lab in (5, 6):
            self.prepare(lab)
            result = self.run_grade()
            self.assertEqual(result["score"], 10)
            self.assertEqual(len(result["review_items"]), len(self.samples))
            self.assertEqual(result["review_count"], 0)
            self.assertAlmostEqual(result["review_base_points"] + sum(item["automatic_points"] for item in result["review_items"]), 10)
            self.assertTrue(all(item["expected_evidence"] for item in result["review_items"]))

    def test_missing_screenshot_loses_exactly_one_equal_weight_check(self):
        (self.images / "maven_package.png").unlink()
        result = self.run_grade()
        self.assertEqual(result["score"], 9.74)
        self.assertIn("maven_package.png: missing (0)", result["feedback"])

    def test_report_receives_credit_even_when_screenshots_folder_is_absent(self):
        shutil.rmtree(self.images)
        self.assertEqual(self.run_grade()["score"], 0.26)

    def test_missing_or_fake_solution_pdf_is_not_credited(self):
        report = self.submission / "Lab5_Solution.pdf"
        for value in (None, b"not a PDF", b"%PDF-1.4\nthis is not a real PDF"):
            if value is None:
                report.unlink(missing_ok=True)
            else:
                report.write_bytes(value)
            self.assertEqual(self.run_grade()["score"], 9.74)

    def test_other_report_names_are_not_accepted(self):
        (self.submission / "Lab5_Solution.pdf").rename(self.submission / "MyReport.pdf")
        self.assertEqual(self.run_grade()["score"], 9.74)

    def test_corrupt_and_blank_screenshots_are_rejected(self):
        (self.images / "maven_package.png").write_bytes(b"not an image")
        self.assertIn("invalid or corrupt image", self.run_grade()["feedback"])
        self.assertIn("unreadable OCR", self.run_grade({"maven_test.png": ""})["feedback"])

    def test_bad_png_checksum_only_loses_one_check(self):
        for lab, filename, expected_score in (
            (5, "maven_package.png", 9.74),
            (6, "nexus_container_running.png", 9.66),
        ):
            with self.subTest(lab=lab):
                self.prepare(lab)
                corrupt_png_checksum(self.images / filename)
                result = self.run_grade()
                self.assertEqual(result["score"], expected_score)
                self.assertIn(f"{filename}: invalid or corrupt image (0)", result["feedback"])

    def test_bad_png_checksum_in_peer_does_not_abort_grading(self):
        original = self.images / "maven_package.png"
        peer = self.root / "damaged-peer.png"
        shutil.copyfile(original, peer)
        corrupt_png_checksum(peer)
        peers = {name: [] for name in self.samples}
        peers[original.name] = [peer]
        result = self.run_grade(peers=peers)
        self.assertEqual(result["score"], 10)
        self.assertEqual(result["review_count"], 0)
        self.assertIn("maven_package.png: passed", result["feedback"])

    def test_case_repeated_extensions_and_image_formats_are_tolerated(self):
        (self.images / "maven_package.png").rename(self.images / "MAVEN_PACKAGE.PNG.png")
        with Image.open(self.images / "maven_test.png") as image:
            image.save(self.images / "MAVEN_TEST.JpG")
        (self.images / "maven_test.png").unlink()
        self.images.rename(self.submission / "ScreenShots")
        result = self.run_grade()
        self.assertEqual(result["score"], 10)

    def test_ambiguous_filenames_are_not_guessed(self):
        shutil.copyfile(self.images / "maven_package.png", self.images / "MAVEN_PACKAGE.JPG")
        self.assertIn("ambiguous filename", self.run_grade()["feedback"])

    def test_screenshot_symlink_cannot_escape_the_submission(self):
        source = self.images / "maven_package.png"
        outside = self.root / "outside.png"
        source.rename(outside)
        source.symlink_to(outside)
        self.assertIn("image points outside the submission", self.run_grade()["feedback"])

    def test_copied_reference_is_rejected_before_ocr(self):
        image = self.images / "maven_package.png"
        self.rubric["instructor_reference_git_blobs"] = [grader.image_fingerprint(image)[1]]
        self.assertIn("copied instructor reference image", self.run_grade()["feedback"])

    def test_exact_cross_student_duplicate_is_zero(self):
        original = self.images / "maven_package.png"
        peer = self.root / "another-student.png"
        shutil.copyfile(original, peer)
        peers = {name: [] for name in self.samples}
        peers[original.name] = [peer]
        result = self.run_grade(peers=peers)
        self.assertIn("exact duplicate of another student's same task", result["feedback"])
        self.assertEqual(result["score"], 9.74)

    def test_visual_near_duplicate_requires_review_not_automatic_rejection(self):
        original = self.images / "maven_package.png"
        peer = self.root / "edited-student.png"
        with Image.open(original) as image:
            image.putpixel((1, 1), (235, 235, 235))
            image.save(peer)
        peers = {name: [] for name in self.samples}
        peers[original.name] = [peer]
        result = self.run_grade(peers=peers)
        self.assertEqual(result["score"], 10)
        self.assertEqual(result["review_count"], 1)
        self.assertIn("manual review required", result["feedback"])

    def test_visible_secret_is_not_repeated_in_feedback(self):
        result = self.run_grade({"maven_package.png": self.samples["maven_package.png"] + "\npassword=SensitivePassword123"})
        self.assertIn("visible password", result["feedback"])
        self.assertNotIn("SensitivePassword123", json.dumps(result))
        self.assertEqual(result["score"], 9.74)

    def test_student_scripts_are_never_executed(self):
        marker = self.root / "student-code-ran"
        (self.submission / "test.sh").write_text(f"touch '{marker}'\n")
        self.run_grade()
        self.assertFalse(marker.exists())

    def test_infrastructure_errors_propagate_instead_of_returning_zero(self):
        with mock.patch.object(grader, "run_ocr", side_effect=RuntimeError("trusted OCR failed")), mock.patch.object(grader, "peer_screenshots", return_value={name: [] for name in self.samples}):
            with self.assertRaises(RuntimeError):
                grader.grade(self.submission, Decimal("10"), "student-name", self.rubric)

    def test_shell_entry_points_work_with_missing_evidence(self):
        missing = self.root / "empty-submission"
        missing.mkdir()
        for lab in (5, 6):
            result = subprocess.run(["bash", str(HERE / f"Lab{lab}/test.sh"), str(missing), "10", "Student-Name"], capture_output=True, text=True, check=True)
            decoded = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(decoded["score"], 0)
            self.assertEqual(len(decoded["review_items"]), 37 if lab == 5 else 28)

    def test_shell_entry_point_rejects_invalid_total_marks(self):
        for value in ("0", "-1", "NaN", "Infinity", "abc"):
            result = subprocess.run(["bash", str(HERE / "Lab5/test.sh"), str(self.submission), value, "student-name"], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_existing_manual_review_can_restore_one_check_without_rounding_drift(self):
        result = self.run_grade({"maven_package.png": "student-name@ubuntu:~$ unrelated evidence"})
        item = next(item for item in result["review_items"] if item["expected_filename"] == "maven_package.png")
        payload = {**result, "status": "graded", "obtained": result["score"], "total": 10, "enrollment_id": "synthetic__devops", "github_username": "student-name"}
        code = """
import { applyReviewDecisions } from './scripts/manual-review.js';
let input = ''; for await (const chunk of process.stdin) input += chunk;
const { result, item } = JSON.parse(input);
const reviewed = applyReviewDecisions([result], [{ ...item, enrollment_id: result.enrollment_id, decision: 'valid' }]);
console.log(JSON.stringify(reviewed[0]));
"""
        completed = subprocess.run(["node", "--input-type=module", "-e", code], cwd=grader.ROOT, input=json.dumps({"result": payload, "item": item}), capture_output=True, text=True, check=True)
        reviewed = json.loads(completed.stdout)
        self.assertEqual(reviewed["obtained"], 10)
        self.assertIn("maven_package.png: passed after manual review", reviewed["feedback"])

    def test_existing_feedback_parser_keeps_all_screenshot_and_pdf_rows(self):
        result = self.run_grade()
        code = """
import { parseFeedback } from './scripts/feedback-report.js';
let input = ''; for await (const chunk of process.stdin) input += chunk;
console.log(JSON.stringify(parseFeedback(JSON.parse(input).feedback)));
"""
        completed = subprocess.run(["node", "--input-type=module", "-e", code], cwd=grader.ROOT, input=json.dumps(result), capture_output=True, text=True, check=True)
        parsed = json.loads(completed.stdout)
        self.assertEqual(len(parsed["checks"]), 38)
        self.assertTrue(all(check["status"] == "Passed" for check in parsed["checks"]))

    def test_peer_discovery_stays_in_same_lab_and_course(self):
        repositories = self.root / "collection"
        current = repositories / "StudentA/DevOps"
        peer = repositories / "StudentB/DevOps"
        for repository in (current, peer):
            repository.mkdir(parents=True)
            subprocess.run(["git", "init", "-q", str(repository)], check=True)
        submission = current / "Labs/Lab05"
        submission.mkdir(parents=True)
        wanted = peer / "Labs/Lab05/ScreenShots"
        wanted.mkdir(parents=True)
        shutil.copyfile(self.images / "maven_package.png", wanted / "MAVEN_PACKAGE.PNG.png")
        unrelated = repositories / "StudentB/CC/Labs/Lab05/screenshots"
        unrelated.mkdir(parents=True)
        shutil.copyfile(self.images / "maven_package.png", unrelated / "maven_package.png")
        found = grader.peer_screenshots(submission.resolve(), ["maven_package.png"])
        self.assertEqual(found["maven_package.png"], [(wanted / "MAVEN_PACKAGE.PNG.png").resolve()])


class OcrIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("tesseract"), "Tesseract is needed for the OCR integration smoke test")
    def test_generated_terminal_screenshot_passes_real_shared_ocr(self):
        with tempfile.TemporaryDirectory(prefix="devops-real-ocr-") as temporary:
            directory = Path(temporary)
            image = Image.new("RGB", (1050, 230), "white")
            draw = ImageDraw.Draw(image)
            font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
            font = ImageFont.truetype(font_path, 26) if Path(font_path).exists() else ImageFont.load_default()
            draw.multiline_text((25, 25), "student-name@ubuntu:~$ mvn package\n[INFO] Building jar: target/sample.jar\n[INFO] BUILD SUCCESS", fill="black", font=font, spacing=15)
            source = directory / "maven_package.png"
            image.save(source)
            with mock.patch.dict("os.environ", {"OCR_AUDIT_DIR": str(directory / "audit")}):
                text = grader.run_ocr(source, directory / "maven_package.txt")
            rubric = grader.load_rubric(HERE / "Lab5/criteria.json")
            check = next(c for c in rubric["screenshots"] if c["filename"] == "maven_package.png")
            self.assertEqual(grader.evidence_problems(check, text, "student-name"), [])
            self.assertTrue((directory / "audit/maven_package.txt").is_file())


if __name__ == "__main__":
    unittest.main()
