#!/usr/bin/env python3

import pathlib
import sys
import tempfile
import unittest

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from scripts.ocr_evidence import prompt_matches, username_matches
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

    def test_prompt_can_span_adjacent_ocr_lines(self):
        self.assertTrue(
            prompt_matches("nidaawajid", "nidaawajid\n@\nubuntu:~$")
        )

    def test_prompt_requires_the_hostname(self):
        self.assertFalse(prompt_matches("nidaawajid", "nidaawajid@debian:~$"))


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
