import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  canonicalScreenshotName,
  normalizeScreenshotFilenames,
  normalizeScreenshotsDirectory
} from "../scripts/screenshot-normalization.js";

test("accepts capitalization variants of the screenshots directory", () => {
  for (const submittedName of ["Screenshots", "SCREENSHOTS", "ScreenShots"]) {
    const submission = mkdtempSync(path.join(os.tmpdir(), "screenshot-folder-"));
    const submitted = path.join(submission, submittedName);
    mkdirSync(submitted);
    writeFileSync(path.join(submitted, "evidence.png"), "image");

    const normalized = normalizeScreenshotsDirectory(submission);

    assert.equal(normalized, path.join(submission, "screenshots"));
    assert.equal(
      existsSync(path.join(submission, "screenshots", "evidence.png")),
      true
    );
  }
});

test("returns null when no screenshots directory exists", () => {
  const submission = mkdtempSync(path.join(os.tmpdir(), "screenshot-missing-"));
  assert.equal(normalizeScreenshotsDirectory(submission), null);
});

test("normalizes screenshot case and repeated image extensions", () => {
  const root = mkdtempSync(path.join(os.tmpdir(), "screenshot-case-"));
  const nested = path.join(root, "part1");
  mkdirSync(nested);
  writeFileSync(path.join(root, "GitHub_Profile.PNG.png"), "profile");
  writeFileSync(path.join(nested, "TASK_OUTPUT.JpG"), "task");

  const result = normalizeScreenshotFilenames(root);

  assert.deepEqual(result, { renamed: 2, ignoredDuplicates: 0 });
  assert.equal(existsSync(path.join(root, "github_profile.png")), true);
  assert.equal(existsSync(path.join(nested, "task_output.png")), true);
});

test("keeps one deterministic file when case variants collide", () => {
  const parent = mkdtempSync(path.join(os.tmpdir(), "screenshot-collision-"));
  const root = path.join(parent, "screenshots");
  mkdirSync(root);
  writeFileSync(path.join(root, "Proof.PNG"), "variant");
  writeFileSync(path.join(root, "proof.png"), "canonical");

  const result = normalizeScreenshotFilenames(root);

  assert.deepEqual(result, { renamed: 0, ignoredDuplicates: 1 });
  assert.deepEqual(readdirSync(root), ["proof.png"]);
  assert.equal(
    existsSync(path.join(parent, ".autograder-ignored-screenshot-name-collisions", "Proof.PNG")),
    true
  );
});

test("leaves non-image files unchanged", () => {
  assert.equal(canonicalScreenshotName("README.md"), null);
  assert.equal(canonicalScreenshotName("Evidence.PDF"), null);
});
