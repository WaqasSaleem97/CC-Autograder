#!/usr/bin/env python3

import pathlib
import sys
import tempfile
import unittest
from unittest import mock

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from scripts.ocr_evidence import (
    credential_exposed,
    prompt_matches,
    username_matches,
)
from scripts.ocr_screenshot import (
    extract_dark_panels,
    extract_bright_fields,
    extract_terminal_lines,
    image_scale_factor,
    needs_enhanced_passes,
    ocr_screenshot,
    prepare_header_region,
)
from scripts.resolve_screenshots import resolve


class IdentityMatchingTests(unittest.TestCase):
    def test_username_matching_is_case_insensitive(self):
        self.assertTrue(username_matches("Student-Name", "STUDENT-NAME"))

    def test_small_ocr_errors_are_tolerated_for_long_usernames(self):
        self.assertTrue(username_matches("ayeshaaafifa", "aueshaaaftifa"))
        self.assertTrue(username_matches("nidaawajid", "nnidaawajid"))

    def test_unrelated_username_is_rejected(self):
        self.assertFalse(username_matches("ayeshaaafifa", "waqassaleem97"))

    def test_username_can_span_adjacent_ocr_lines(self):
        self.assertTrue(
            username_matches(
                "shanzaanum7-hub",
                "https://shi\naanum7-hub.github.io",
            )
        )

    def test_username_tolerates_stronger_distortion_only_in_github_url(self):
        self.assertTrue(
            username_matches(
                "nibasadiq",
                "https://gtebcon/nbssdiqitbsadeathubicnetingy/pages",
            )
        )
        self.assertFalse(username_matches("nibasadiq", "student nbssdiq profile"))
        self.assertFalse(
            username_matches(
                "nibasadiq",
                "https://github.com/completelydifferent/settings",
            )
        )

    def test_prompt_can_span_adjacent_ocr_lines(self):
        self.assertTrue(
            prompt_matches("nidaawajid", "nidaawajid\n@\nubuntu:~$")
        )

    def test_prompt_requires_the_hostname(self):
        self.assertFalse(prompt_matches("nidaawajid", "nidaawajid@debian:~$"))

    def test_prompt_tolerates_at_sign_joined_to_ubuntu_by_ocr(self):
        self.assertTrue(
            prompt_matches(
                "taneeszahra",
                "taneeszahragubuntu:~/Assignment01$",
            )
        )

    def test_prompt_tolerates_ocr_letters_in_a_numeric_suffix(self):
        self.assertTrue(
            prompt_matches(
                "FizaJabbar050",
                "fizajabbareSe@ubuntu:~/Assignment01$",
            )
        )
        self.assertTrue(
            prompt_matches(
                "LaibaSaleem066",
                "laihasaleemesé@ubuntu:~/Assignment01$",
            )
        )

    def test_prompt_does_not_accept_an_omitted_numeric_suffix(self):
        self.assertFalse(
            prompt_matches("FizaJabbar050", "fizajabbar@ubuntu:~/Assignment01$")
        )

    def test_prompt_does_not_accept_an_abbreviated_username(self):
        self.assertFalse(
            prompt_matches("areebahabib", "areeba@ubuntu:~/Assignment01$")
        )


class CredentialDetectionTests(unittest.TestCase):
    def test_normal_url_and_later_ubuntu_prompt_are_not_joined(self):
        text = """\
curl http://127.0.0.1:3000/
Gitea HTTP status: 200
student@ubuntu:~/Gitea$
"""
        self.assertFalse(credential_exposed(text))

    def test_visible_github_token_is_rejected(self):
        self.assertTrue(credential_exposed("token=ghp_" + "a" * 36))

    def test_normal_git_authentication_prompts_are_not_credentials(self):
        text = """\
Username for 'https://github.com': student-name
Password for 'https://student-name@github.com':
student-name@ubuntu:~/Assignment01$
"""
        self.assertFalse(credential_exposed(text))
        self.assertFalse(
            credential_exposed(
                "student-name@ubuntu Username for 'https://github.com': student-name"
            )
        )

    def test_normal_gitea_password_prompt_is_not_a_credential(self):
        self.assertFalse(
            credential_exposed(
                "Password for 'http://student@127.0.0.1:3000':"
            )
        )

    def test_password_bearing_url_is_rejected(self):
        self.assertTrue(
            credential_exposed(
                "git remote add gitea http://student:visible-password@127.0.0.1/repo"
            )
        )

    def test_password_bearing_url_inside_prompt_is_rejected(self):
        self.assertTrue(
            credential_exposed(
                "Password for 'http://student:visible-password@127.0.0.1:3000':"
            )
        )
        self.assertTrue(
            credential_exposed(
                "Password for 'http://student : visible-password @ 127.0.0.1:3000':"
            )
        )


class ScreenshotResolutionTests(unittest.TestCase):
    def test_case_and_repeated_extensions_are_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            screenshot = directory / "GitHub_Profile.PNG.png"
            screenshot.write_bytes(b"image")
            self.assertEqual(
                resolve(directory, ["github_profile.png"]),
                [("github_profile.png", str(screenshot.resolve()))],
            )

    def test_multiple_matching_extensions_are_ambiguous(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            (directory / "proof.png").write_bytes(b"one")
            (directory / "proof.jpg").write_bytes(b"two")
            self.assertEqual(
                resolve(directory, ["proof.png"]),
                [("proof.png", "__AMBIGUOUS__")],
            )


class BrightFieldTests(unittest.TestCase):
    def test_long_bright_installer_field_is_extracted(self):
        image = Image.new("RGB", (800, 240), "#111111")
        drawing = ImageDraw.Draw(image)
        drawing.rectangle((220, 120, 760, 142), fill="white")
        fields = extract_bright_fields(image)
        self.assertTrue(fields)
        self.assertGreater(fields[0].width, fields[0].height * 4)

    def test_embedded_dark_terminal_panel_is_extracted(self):
        image = Image.new("RGB", (1200, 700), "white")
        drawing = ImageDraw.Draw(image)
        drawing.rectangle((260, 160, 1060, 610), fill="#111111")
        drawing.text((300, 210), "student@ubuntu git lfs ls-files", fill="white")
        panels = extract_dark_panels(image)
        self.assertTrue(panels)
        self.assertGreater(panels[0].width, 500)

    def test_tiny_terminal_rows_are_extracted_without_size_rejection(self):
        image = Image.new("RGB", (900, 260), "white")
        drawing = ImageDraw.Draw(image)
        drawing.rectangle((180, 70, 890, 255), fill="#111111")
        for y, text in enumerate(
            (
                "student@ubuntu docker compose ps",
                "gitea gitea/gitea latest Up",
                "gitea_db postgres 17 alpine Up",
                "Gitea HTTP status 200",
            ),
            start=1,
        ):
            drawing.text((200, 70 + y * 22), text, fill="white")
        sheet = extract_terminal_lines(image)
        self.assertIsNotNone(sheet)
        self.assertGreater(sheet.height, 100)
        self.assertGreater(sheet.width, sheet.height)

    def test_browser_header_region_is_prepared_without_fixed_dimensions(self):
        image = Image.new("RGB", (1000, 600), "white")
        header = prepare_header_region(image)
        self.assertIsNotNone(header)
        self.assertGreater(header.width, header.height)


class AdaptiveOcrTests(unittest.TestCase):
    def test_small_and_narrow_images_are_upscaled_not_rejected(self):
        self.assertGreater(image_scale_factor((792, 94)), 1)
        self.assertGreater(image_scale_factor((80, 30)), 1)

    def test_large_image_does_not_need_an_ocr_upscale(self):
        self.assertEqual(image_scale_factor((1920, 1080)), 1)

    def test_dark_or_small_images_receive_enhanced_passes(self):
        dark = Image.new("RGB", (1920, 1080), "black")
        small = Image.new("RGB", (500, 100), "white")
        strong_text = "terminal evidence " * 10
        self.assertTrue(needs_enhanced_passes(dark, 0, strong_text))
        self.assertTrue(needs_enhanced_passes(small, 255, strong_text))

    @mock.patch(
        "scripts.ocr_screenshot.run_tesseract",
        return_value="valid terminal evidence with enough recognised characters",
    )
    def test_tiny_decodable_image_is_processed(self, mocked_tesseract):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "tiny.png"
            Image.new("RGB", (32, 12), "white").save(path)
            self.assertIn("valid terminal evidence", ocr_screenshot(path))
            self.assertGreaterEqual(mocked_tesseract.call_count, 2)


if __name__ == "__main__":
    unittest.main()
