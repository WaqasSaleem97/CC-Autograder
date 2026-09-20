#!/usr/bin/env python3
"""Run resilient OCR for screenshots used by the grading scripts.

The normal OCR passes handle browser pages and terminals.  A final pass extracts
bright input fields, which is important for Ubuntu Server's dark installer UI:
Tesseract often reads the labels but otherwise misses the text inside the white
fields.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
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
        ],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    return result.stdout


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
    pixels = gray.load()
    bright_threshold = 190

    bright_rows: list[bool] = []
    minimum_bright_pixels = max(40, int(width * 0.25))
    for y in range(height):
        count = sum(pixels[x, y] >= bright_threshold for x in range(width))
        bright_rows.append(count >= minimum_bright_pixels)

    fields: list[Image.Image] = []
    maximum_field_height = max(20, int(height * 0.20))
    for top, bottom in _runs(bright_rows):
        field_height = bottom - top
        if field_height < 5 or field_height > maximum_field_height:
            continue

        bright_columns: list[bool] = []
        required = max(1, int(field_height * 0.45))
        for x in range(width):
            count = sum(
                pixels[x, y] >= bright_threshold for y in range(top, bottom)
            )
            bright_columns.append(count >= required)

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
        gray = ImageOps.autocontrast(source.convert("L"), cutoff=1)
        scale = 2 if max(gray.size) < 2400 else 1
        if scale > 1:
            gray = gray.resize(
                (gray.width * scale, gray.height * scale),
                Image.Resampling.LANCZOS,
            )

        gray_path = directory / "gray.png"
        binary_path = directory / "binary.png"
        gray.save(gray_path)

        binary = ImageOps.invert(gray) if ImageStat.Stat(gray).mean[0] < 127 else gray
        binary.point(lambda value: 255 if value > 100 else 0).save(binary_path)

        output = [
            run_tesseract(source_path, 11),
            run_tesseract(gray_path, 6),
            run_tesseract(gray_path, 11),
            run_tesseract(binary_path, 12),
        ]

        sheet = build_field_sheet(extract_bright_fields(source))
        if sheet is not None:
            field_path = directory / "fields.png"
            sheet.save(field_path)
            output.append(run_tesseract(field_path, 6))
            output.append(run_tesseract(field_path, 11))

    return "\n".join(output)


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
