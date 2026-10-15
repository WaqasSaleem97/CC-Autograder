import assert from "node:assert/strict";
import test from "node:test";
import { applyReviewDecisions, buildReferenceCriteria, invalidReferenceReviewItems, isCleanFullCreditReference, reviewedFeedback } from "../../scripts/manual-review.js";

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

test("every clean full-credit image becomes a selected reference candidate", () => {
  const base = {
    criterionId: "question-2",
    criterionOrder: 1,
    criterionLabel: "Question 2",
    expectedName: "task2_remotes.png",
    expectedEvidence: ["Show both remotes."],
    automaticStatus: "Passed",
    automaticPoints: 1,
    maxPoints: 1,
    auditCategory: "Automatic pass",
    duplicateReferences: [],
    source: "/tmp/image.png"
  };
  const records = [
    { ...base, enrollmentId: "student-01__cc", registration: "2024-BSE-01", username: "student01", hash: "a".repeat(64), submittedPath: "screenshots/task2_remotes.png" },
    { ...base, enrollmentId: "student-02__cc", registration: "2024-BSE-02", username: "student02", hash: "b".repeat(64), submittedPath: "screenshots/task2_remotes.png" },
    { ...base, enrollmentId: "student-03__cc", registration: "2024-BSE-03", username: "student03", hash: "c".repeat(64), duplicateReferences: ["2024-BSE-04: task2_remotes.png"], auditCategory: "Possible false positive" },
    { ...base, enrollmentId: "student-04__cc", registration: "2024-BSE-04", username: "student04", hash: "d".repeat(64), automaticStatus: "Failed", automaticPoints: 0, auditCategory: "Possible false negative" }
  ];
  const criteria = buildReferenceCriteria(records, {
    studentImageUrl: (record) => `https://raw.githubusercontent.com/example/CC/commit/${record.registration}.png`
  });
  assert.equal(criteria.length, 1);
  assert.deepEqual(criteria[0].reference_candidates.map((candidate) => candidate.registration_number), ["2024-BSE-01", "2024-BSE-02"]);
  assert.deepEqual(criteria[0].reference_candidates.map((candidate) => candidate.enrollment_id), ["student-01__cc", "student-02__cc"]);
  assert.deepEqual(criteria[0].selected_reference_ids, criteria[0].reference_candidate_ids);
  assert.equal(isCleanFullCreditReference(records[0]), true);
  assert.equal(isCleanFullCreditReference(records[2]), false);
});

test("removing one expected image deducts only its owner's matching criterion", () => {
  const criterion = {
    criterion_id: "question-2",
    criterion_order: 1,
    criterion_label: "Question 2",
    expected_filename: "task2_remotes.png",
    selected_reference_ids: ["candidate-02"],
    reference_candidates: [
      { id: "candidate-01", source: "student-full-credit", enrollment_id: "student-01__cc", registration_number: "2024-BSE-01", github_username: "student01", automatic_points: 1, max_points: 1 },
      { id: "candidate-02", source: "student-full-credit", enrollment_id: "student-02__cc", registration_number: "2024-BSE-02", github_username: "student02", automatic_points: 1, max_points: 1 }
    ]
  };
  const deductions = invalidReferenceReviewItems([criterion]);
  assert.equal(deductions.length, 1);
  assert.equal(deductions[0].enrollment_id, "student-01__cc");
  assert.equal(deductions[0].expected_filename, "task2_remotes.png");
  assert.equal(deductions[0].decision, "invalid");

  const results = [
    { enrollment_id: "student-01__cc", github_username: "student01", status: "graded", obtained: 10, total: 10, feedback: "Passed 10/10 checks. task2_remotes.png: passed; other.png: passed" },
    { enrollment_id: "student-02__cc", github_username: "student02", status: "graded", obtained: 10, total: 10, feedback: "Passed 10/10 checks. task2_remotes.png: passed; other.png: passed" }
  ];
  const reviewed = applyReviewDecisions(results, deductions);
  assert.equal(reviewed[0].obtained, 9);
  assert.match(reviewed[0].feedback, /task2_remotes\.png: failed after manual review \(0\)/);
  assert.match(reviewed[0].feedback, /other\.png: passed/);
  assert.equal(reviewed[1].obtained, 10);
  assert.doesNotMatch(reviewed[1].feedback, /^Final score/);
});
