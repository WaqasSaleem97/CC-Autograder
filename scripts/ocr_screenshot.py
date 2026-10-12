#!/usr/bin/env python3
"""Run dimension-independent adaptive OCR for grading screenshots.

Every image receives complementary sparse-text and block-text passes. Small,
narrow, dark, or weakly recognised images receive additional enhanced passes.
No image earns or loses marks because of its pixel dimensions: small images are
upscaled for OCR, while the original evidence remains unchanged.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import math
import re
from pathlib import Path

from PIL import Image, ImageOps, ImageStat


def run_tesseract(image: Path, page_segmentation_mode: int) -> str:
    result = subprocess.run(
        [
            "tesseract",
            str(image),
            "stdout",
            "--psm",
            str(page_segmentation_mode),
            "--dpi",
            "300",
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout


def image_scale_factor(size: tuple[int, int]) -> int:
    """Choose a safe OCR-only upscale factor without rejecting any dimensions."""

    width, height = size
    if width <= 0 or height <= 0:
        return 1

    shortest = min(width, height)
    longest = max(width, height)
    factor = max(
        1,
        math.ceil(240 / shortest),
        math.ceil(1600 / longest),
    )
    factor = min(6, factor)

    # Avoid creating an unnecessarily large working copy. This limits only the
    # temporary OCR resize; it does not reject or penalise the submitted image.
    while factor > 1 and width * height * factor * factor > 12_000_000:
        factor -= 1
    return factor


def needs_enhanced_passes(
    source: Image.Image, grayscale_mean: float, fast_text: str
) -> bool:
    """Select extra OCR passes for layouts that commonly confuse Tesseract."""

    width, height = source.size
    shortest = max(1, min(width, height))
    longest = max(width, height)
    alphanumeric_count = len(re.findall(r"[a-z0-9]", fast_text.casefold()))
    return (
        image_scale_factor(source.size) > 1
        or grayscale_mean < 150
        or longest / shortest >= 3.5
        or alphanumeric_count < 40
    )


def _runs(values: list[bool]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    start: int | None = None
    for index, enabled in enumerate([*values, False]):
        if enabled and start is None:
            start = index
        elif not enabled and start is not None:
            result.append((start, index))
            start = None
    return result


def _longest_segment_with_small_gaps(
    columns: list[bool], maximum_gap: int
) -> tuple[int, int] | None:
    enabled = [index for index, value in enumerate(columns) if value]
    if not enabled:
        return None

    segments: list[tuple[int, int]] = []
    start = enabled[0]
    previous = enabled[0]
    for column in enabled[1:]:
        if column - previous > maximum_gap:
            segments.append((start, previous + 1))
            start = column
        previous = column
    segments.append((start, previous + 1))
    return max(segments, key=lambda segment: segment[1] - segment[0])


def extract_bright_fields(source: Image.Image) -> list[Image.Image]:
    """Extract long, bright form fields without assuming fixed coordinates."""

    gray = source.convert("L")
    width, height = gray.size
    bright_threshold = 190
    mask = gray.point(lambda value: 255 if value >= bright_threshold else 0)

    # BOX projections run inside Pillow instead of scanning every source pixel
    # in Python, which keeps full-class grading practical for large images.
    row_projection = mask.resize((1, height), Image.Resampling.BOX)
    minimum_row_ratio = max(40 / max(1, width), 0.25)
    bright_rows = [
        value >= round(255 * minimum_row_ratio)
        for value in row_projection.tobytes()
    ]

    fields: list[Image.Image] = []
    maximum_field_height = max(20, int(height * 0.20))
    for top, bottom in _runs(bright_rows):
        field_height = bottom - top
        if field_height < 5 or field_height > maximum_field_height:
            continue

        field_mask = mask.crop((0, top, width, bottom))
        column_projection = field_mask.resize((width, 1), Image.Resampling.BOX)
        bright_columns = [
            value >= round(255 * 0.45)
            for value in column_projection.tobytes()
        ]

        segment = _longest_segment_with_small_gaps(
            bright_columns,
            maximum_gap=max(6, int(width * 0.008)),
        )
        if segment is None:
            continue
        left, right = segment
        if right - left < max(80, int(width * 0.12)):
            continue

        field = ImageOps.autocontrast(gray.crop((left, top, right, bottom)))
        scale = min(8, max(3, (96 + field.height - 1) // field.height))
        field = field.resize(
            (field.width * scale, field.height * scale),
            Image.Resampling.LANCZOS,
        )
        fields.append(ImageOps.expand(field, border=12, fill="white"))
        if len(fields) >= 16:
            break

    return fields


def build_field_sheet(fields: list[Image.Image]) -> Image.Image | None:
    if not fields:
        return None

    maximum_width = min(6000, max(field.width for field in fields))
    normalized: list[Image.Image] = []
    for field in fields:
        if field.width > maximum_width:
            ratio = maximum_width / field.width
            field = field.resize(
                (maximum_width, max(1, round(field.height * ratio))),
                Image.Resampling.LANCZOS,
            )
        normalized.append(field)

    sheet = Image.new(
        "L",
        (maximum_width, sum(field.height for field in normalized)),
        "white",
    )
    y = 0
    for field in normalized:
        sheet.paste(field, (0, y))
        y += field.height
    return sheet


def ocr_screenshot(source_path: Path) -> str:
    with Image.open(source_path) as opened:
        source = ImageOps.exif_transpose(opened).convert("RGB")

    with tempfile.TemporaryDirectory(prefix="grader-ocr-") as temporary:
        directory = Path(temporary)
        original_gray = source.convert("L")
        grayscale_mean = ImageStat.Stat(original_gray).mean[0]
        gray = ImageOps.autocontrast(original_gray, cutoff=1)
        scale = image_scale_factor(gray.size)
        if scale > 1:
            gray = gray.resize(
                (gray.width * scale, gray.height * scale),
                Image.Resampling.LANCZOS,
            )

        gray_path = directory / "gray.png"
        binary_path = directory / "binary.png"
        ImageOps.expand(gray, border=12, fill="white").save(gray_path)

        binary = ImageOps.invert(gray) if grayscale_mean < 127 else gray
        binary = binary.point(lambda value: 255 if value > 100 else 0)
        ImageOps.expand(binary, border=12, fill="white").save(binary_path)

        fast_text = run_tesseract(source_path, 11)
        output = [fast_text, run_tesseract(gray_path, 6)]

        if needs_enhanced_passes(source, grayscale_mean, fast_text):
            output.append(run_tesseract(gray_path, 11))
            output.append(run_tesseract(binary_path, 12))

        # Bright installer fields matter primarily on dark setup screens. Skip
        # this specialised work for normal browser pages and light terminals.
        if grayscale_mean < 150:
            sheet = build_field_sheet(extract_bright_fields(source))
            if sheet is not None:
                field_path = directory / "fields.png"
                sheet.save(field_path)
                output.append(run_tesseract(field_path, 6))
                output.append(run_tesseract(field_path, 11))

    unique_output: list[str] = []
    seen: set[str] = set()
    for text in output:
        normalized = " ".join(text.split()).casefold()
        if normalized and normalized not in seen:
            seen.add(normalized)
            unique_output.append(text)
    return "\n".join(unique_output)


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: ocr_screenshot.py SOURCE_IMAGE OUTPUT_TEXT", file=sys.stderr)
        return 2

    source = Path(sys.argv[1])
    output = Path(sys.argv[2])
    try:
        text = ocr_screenshot(source)
    except Exception as error:  # The grader reports unreadable OCR downstream.
        print(f"OCR failed for {source}: {error}", file=sys.stderr)
        text = ""
    output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
