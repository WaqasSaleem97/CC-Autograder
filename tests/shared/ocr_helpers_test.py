#!/usr/bin/env python3

import pathlib
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))

from scripts.ocr_evidence import (
    credential_exposed,
    prompt_matches,
    username_matches,
)
from scripts.ocr_screenshot import extract_bright_fields
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

    def test_password_bearing_url_is_rejected(self):
        self.assertTrue(
            credential_exposed(
                "git remote add gitea http://student:visible-password@127.0.0.1/repo"
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


if __name__ == "__main__":
    unittest.main()
