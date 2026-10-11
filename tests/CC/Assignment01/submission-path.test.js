import assert from "node:assert/strict";
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import {
  findSubmissionDirectory,
  normalizeSubmissionDirectory
} from "../../../scripts/submission-path.js";

const withRepository = (callback) => {
  const repository = mkdtempSync(path.join(tmpdir(), "assignment01-path-"));
  try {
    callback(repository);
  } finally {
    rmSync(repository, { recursive: true, force: true });
  }
};

test("prefers the documented Assignment01 directory", () => {
  withRepository((repository) => {
    mkdirSync(path.join(repository, "Assignments", "Assignment01"), {
      recursive: true
    });
    mkdirSync(path.join(repository, "Assignment", "Assignment01"), {
      recursive: true
    });

    const found = findSubmissionDirectory(
      repository,
      "Assignments/Assignment01",
      "CC"
    );
    assert.equal(found.relativePath, "Assignments/Assignment01");
  });
});

test("accepts and normalizes the observed singular Assignment folder", () => {
  withRepository((repository) => {
    const alternate = path.join(repository, "Assignment", "Assignment01");
    mkdirSync(alternate, { recursive: true });

    const normalized = normalizeSubmissionDirectory(
      repository,
      "Assignments/Assignment01",
      "CC"
    );
    assert.equal(normalized.originalRelativePath, "Assignment/Assignment01");
    assert.ok(existsSync(path.join(repository, "Assignments", "Assignment01")));
    assert.equal(existsSync(alternate), false);
  });
});

test("accepts and normalizes the observed extra CC directory", () => {
  withRepository((repository) => {
    mkdirSync(
      path.join(repository, "CC", "Assignments", "Assignment01"),
      { recursive: true }
    );

    const normalized = normalizeSubmissionDirectory(
      repository,
      "Assignments/Assignment01",
      "CC"
    );
    assert.equal(
      normalized.originalRelativePath,
      "CC/Assignments/Assignment01"
    );
    assert.ok(existsSync(path.join(repository, "Assignments", "Assignment01")));
  });
});

test("does not accept an unrelated Assignment01 directory", () => {
  withRepository((repository) => {
    mkdirSync(path.join(repository, "random", "Assignment01"), {
      recursive: true
    });

    const found = findSubmissionDirectory(
      repository,
      "Assignments/Assignment01",
      "CC"
    );
    assert.equal(found, null);
  });
});
