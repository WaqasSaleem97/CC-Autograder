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
import os
import re
from pathlib import Path

from PIL import Image, ImageFilter, ImageOps, ImageStat


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


def _dark_panel_bounds(source: Image.Image) -> list[tuple[int, int, int, int]]:
    """Locate embedded terminal panels without fixed screen coordinates."""

    gray = source.convert("L")
    width, height = gray.size
    if width < 160 or height < 100:
        return []

    dark_mask = gray.point(lambda value: 255 if value <= 105 else 0)
    row_projection = dark_mask.resize((1, height), Image.Resampling.BOX)
    dark_rows = [value >= round(255 * 0.20) for value in row_projection.tobytes()]

    bounds: list[tuple[int, int, int, int]] = []
    for top, bottom in _runs(dark_rows):
        if bottom - top < max(35, int(height * 0.07)):
            continue
        row_mask = dark_mask.crop((0, top, width, bottom))
        column_projection = row_mask.resize((width, 1), Image.Resampling.BOX)
        dark_columns = [
            value >= round(255 * 0.35)
            for value in column_projection.tobytes()
        ]
        segment = _longest_segment_with_small_gaps(
            dark_columns,
            maximum_gap=max(8, int(width * 0.012)),
        )
        if segment is None:
            continue
        left, right = segment
        if right - left < max(140, int(width * 0.22)):
            continue

        margin_x = max(4, int(width * 0.008))
        margin_y = max(4, int(height * 0.008))
        panel_bounds = (
            max(0, left - margin_x),
            max(0, top - margin_y),
            min(width, right + margin_x),
            min(height, bottom + margin_y),
        )
        panel = gray.crop(panel_bounds)
        if ImageStat.Stat(panel).stddev[0] < 12:
            continue

        bounds.append(panel_bounds)
        if len(bounds) >= 3:
            break
    return bounds


def extract_dark_panels(source: Image.Image) -> list[Image.Image]:
    """Extract embedded terminal panels without fixed screen coordinates."""

    gray = source.convert("L")
    panels: list[Image.Image] = []
    for panel_bounds in _dark_panel_bounds(source):
        panel = gray.crop(panel_bounds)

        panel = ImageOps.autocontrast(ImageOps.invert(panel), cutoff=1)
        scale = max(1, min(6, math.ceil(2200 / max(1, panel.width))))
        while scale > 1 and panel.width * panel.height * scale * scale > 8_000_000:
            scale -= 1
        if scale > 1:
            panel = panel.resize(
                (panel.width * scale, panel.height * scale),
                Image.Resampling.LANCZOS,
            )
        panels.append(
            ImageOps.expand(panel.filter(ImageFilter.SHARPEN), border=12, fill="white")
        )
    return panels


def extract_terminal_lines(source: Image.Image) -> Image.Image | None:
    """Build an OCR sheet from tiny text rows inside dark terminal panels.

    A whole-screen screenshot can make otherwise legible terminal characters
    only a few pixels high. Segmenting the rows before enlarging them preserves
    their shapes better than enlarging the entire desktop and does not impose a
    minimum source-image size.
    """

    gray = source.convert("L")
    lines: list[Image.Image] = []

    for left, top, right, bottom in _dark_panel_bounds(source):
        panel = gray.crop((left, top, right, bottom))
        inset = max(2, min(12, round(min(panel.size) * 0.04)))
        if panel.width > inset * 2 and panel.height > inset * 2:
            panel = panel.crop(
                (inset, inset, panel.width - inset, panel.height - inset)
            )
        width, height = panel.size
        pixels = panel.load()
        background_mean = ImageStat.Stat(panel).mean[0]
        bright_threshold = max(70, min(150, round(background_mean + 55)))
        minimum_bright_pixels = max(3, round(width * 0.004))
        active_rows = [
            sum(pixels[x, y] >= bright_threshold for x in range(width))
            >= minimum_bright_pixels
            for y in range(height)
        ]

        maximum_line_height = max(20, round(height * 0.12))
        for row_top, row_bottom in _runs(active_rows):
            if not 2 <= row_bottom - row_top <= maximum_line_height:
                continue

            row_top = max(0, row_top - 1)
            row_bottom = min(height, row_bottom + 1)
            bright_columns = [
                x
                for y in range(row_top, row_bottom)
                for x in range(width)
                if pixels[x, y] >= bright_threshold
            ]
            if not bright_columns:
                continue

            line_left = max(0, min(bright_columns) - 2)
            line_right = min(width, max(bright_columns) + 3)
            line = panel.crop((line_left, row_top, line_right, row_bottom))
            line = ImageOps.autocontrast(ImageOps.invert(line), cutoff=1)
            scale = max(3, math.ceil(48 / max(1, line.height)))
            line = line.resize(
                (line.width * scale, line.height * scale),
                Image.Resampling.NEAREST,
            )
            lines.append(ImageOps.expand(line, border=(12, 6), fill="white"))
            if len(lines) >= 40:
                break
        if len(lines) >= 40:
            break

    if not lines:
        return None

    sheet_height = sum(line.height + 6 for line in lines)
    maximum_width = min(6500, max(line.width for line in lines))
    if sheet_height * maximum_width > 8_000_000:
        maximum_width = max(1200, 8_000_000 // max(1, sheet_height))

    sheet = Image.new("L", (maximum_width, sheet_height), "white")
    y = 0
    for line in lines:
        if line.width > maximum_width:
            ratio = maximum_width / line.width
            line = line.resize(
                (maximum_width, max(1, round(line.height * ratio))),
                Image.Resampling.LANCZOS,
            )
        sheet.paste(line, (0, y))
        y += line.height + 6
    return sheet


def prepare_header_region(source: Image.Image) -> Image.Image | None:
    """Prepare a browser/header strip when whole-image OCR is weak."""

    width, height = source.size
    if width < 320 or height < 180:
        return None
    header = source.crop((0, 0, width, max(80, int(height * 0.24)))).convert("L")
    header = ImageOps.autocontrast(header, cutoff=1)
    scale = max(1, min(4, math.ceil(1400 / max(1, header.width))))
    if scale > 1:
        header = header.resize(
            (header.width * scale, header.height * scale),
            Image.Resampling.LANCZOS,
        )
    return ImageOps.expand(header.filter(ImageFilter.SHARPEN), border=12, fill="white")


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
        binary = binary.point(lambda value: 255 if value > 150 else 0)
        ImageOps.expand(binary, border=12, fill="white").save(binary_path)

        fast_text = run_tesseract(source_path, 11)
        output = [fast_text, run_tesseract(gray_path, 6)]

        if needs_enhanced_passes(source, grayscale_mean, fast_text):
            output.append(run_tesseract(gray_path, 11))
            output.append(run_tesseract(binary_path, 12))

        alphanumeric_count = len(re.findall(r"[a-z0-9]", fast_text.casefold()))
        has_dark_panels = bool(_dark_panel_bounds(source))
        if has_dark_panels and (grayscale_mean >= 150 or alphanumeric_count < 120):
            terminal_lines = extract_terminal_lines(source)
            if terminal_lines is not None:
                panel_path = directory / "terminal-lines.png"
                terminal_lines.save(panel_path)
                output.append(run_tesseract(panel_path, 11))
            else:
                dark_panels = extract_dark_panels(source)
                panel_sheet = build_field_sheet(dark_panels)
                if panel_sheet is not None:
                    panel_path = directory / "dark-panels.png"
                    panel_sheet.save(panel_path)
                    output.append(run_tesseract(panel_path, 6))

        if alphanumeric_count < 160 and not re.search(
            r"(?:https?://|github|gitea|[.]io\b)", fast_text, re.IGNORECASE
        ):
            header = prepare_header_region(source)
            if header is not None:
                header_path = directory / "header.png"
                header.save(header_path)
                output.append(run_tesseract(header_path, 11))

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

    # The grading workflow may request a persistent, per-student copy for the
    # manual image-audit report. Individual test scripts can continue using
    # temporary OCR directories; this shared helper handles the audit copy for
    # every present and future screenshot-based assessment.
    audit_directory = os.environ.get("OCR_AUDIT_DIR", "").strip()
    if audit_directory:
        audit_output = Path(audit_directory) / output.name
        audit_output.parent.mkdir(parents=True, exist_ok=True)
        audit_output.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
