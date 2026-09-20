import assert from "node:assert/strict";
import test from "node:test";
import { parseFeedback, statusColors } from "../scripts/feedback-report.js";

test("parses provisional Lab1 credit as a manual-review result", () => {
  const report = parseFeedback(
    "Passed 44/45 Lab 01 checks; 1 check(s) received provisional credit and require manual review. "
    + "ubuntu_username.png: manual review recommended - GitHub username was not confidently detected, required task evidence was not confidently detected (provisional credit);"
    + "lab01_folder_structure.png: missing (0);github_profile.png: passed"
  );

  assert.equal(
    report.summary,
    "Passed 44/45 Lab 01 checks; 1 check(s) received provisional credit and require manual review."
  );
  assert.deepEqual(report.checks, [
    {
      name: "ubuntu_username.png",
      status: "Manual review",
      details: "GitHub username was not confidently detected, required task evidence was not confidently detected."
    },
    {
      name: "lab01_folder_structure.png",
      status: "Missing",
      details: "Required file was not found."
    },
    {
      name: "github_profile.png",
      status: "Passed",
      details: "Required evidence detected."
    }
  ]);
});

test("uses a visible warning color for manual review", () => {
  assert.deepEqual(statusColors("Manual review"), {
    text: "#7d4e00",
    background: "#fff8c5"
  });
});
