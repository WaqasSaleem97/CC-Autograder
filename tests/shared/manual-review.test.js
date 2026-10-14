import assert from "node:assert/strict";
import test from "node:test";
import { applyReviewDecisions, reviewedFeedback } from "../../scripts/manual-review.js";

const baseResult = {
  enrollment_id: "test-student__cc",
  github_username: "test-student",
  status: "graded",
  obtained: 7,
  total: 10,
  review_count: 2,
  review_required: true,
  feedback: "Passed 7/10 checks. first.png: required evidence was not detected (0); second.png: passed; report.pdf: passed"
};

test("valid and invalid review decisions replace only their criterion points", () => {
  const items = [
    { id: "one", enrollment_id: baseResult.enrollment_id, criterion_id: "first", expected_filename: "first.png", automatic_points: 0, max_points: 1, decision: "valid" },
    { id: "two", enrollment_id: baseResult.enrollment_id, criterion_id: "second", expected_filename: "second.png", automatic_points: 1, max_points: 1, decision: "invalid" }
  ];
  const [result] = applyReviewDecisions([baseResult], items);
  assert.equal(result.obtained, 7);
  assert.equal(result.automatic_obtained, 7);
  assert.equal(result.review_count, 0);
  assert.equal(result.review_required, false);
  assert.match(result.feedback, /^Final score 7\/10 after manual review\./);
  assert.match(result.feedback, /first\.png: passed after manual review/);
  assert.match(result.feedback, /second\.png: failed after manual review \(0\)/);
});

test("review later prevents finalization", () => {
  assert.throws(() => applyReviewDecisions([baseResult], [{
    id: "pending", enrollment_id: baseResult.enrollment_id, expected_filename: "first.png",
    automatic_points: 0, max_points: 1, decision: "review-later"
  }]), /still pending/);
});

test("reviewed feedback preserves unreviewed checks", () => {
  const feedback = reviewedFeedback(baseResult.feedback, [{
    expected_filename: "first.PNG.png", decision: "valid"
  }], 8, 10);
  assert.match(feedback, /first\.png: passed after manual review/);
  assert.match(feedback, /second\.png: passed/);
  assert.match(feedback, /report\.pdf: passed/);
});

test("structured grading recomputes from the exact non-image base", () => {
  const result = {
    ...baseResult,
    obtained: 6.67,
    review_base_points: 0.67,
    review_items: [
      { expected_filename: "first.png", automatic_points: 0, max_points: 0.75 },
      { expected_filename: "second.png", automatic_points: 0.6, max_points: 0.75 },
      { expected_filename: "third.png", automatic_points: 5.4, max_points: 8.5 }
    ]
  };
  const [reviewed] = applyReviewDecisions([result], [{
    id: "one", enrollment_id: result.enrollment_id, criterion_id: "first", expected_filename: "first.png",
    automatic_points: 0, max_points: 0.75, decision: "valid"
  }]);
  assert.equal(reviewed.obtained, 7.42);
});
