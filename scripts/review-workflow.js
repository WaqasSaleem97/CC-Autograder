import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";
import { applyReviewDecisions, resultKey } from "./manual-review.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const command = String(process.argv[2] || "").trim().toLowerCase();
const projectId = String(process.env.FIREBASE_PROJECT_ID || "").trim();
const gradingRunId = String(process.env.GRADING_RUN_ID || process.env.GITHUB_RUN_ID || "").trim();

if (!projectId) throw new Error("FIREBASE_PROJECT_ID is required.");
if (!/^\d{1,30}$/.test(gradingRunId)) throw new Error("A numeric GRADING_RUN_ID or GITHUB_RUN_ID is required.");
if (!["stage", "prepare", "complete", "fail"].includes(command)) throw new Error("Use: review-workflow.js stage|prepare|complete|fail");

initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
const runRef = db.collection("grading_runs").doc(gradingRunId);
const readJson = (relative) => JSON.parse(readFileSync(path.join(root, relative), "utf8"));
const envBoolean = (name) => String(process.env[name] || "").toLowerCase() === "true";

if (command === "stage") await stageReview();
if (command === "prepare") await prepareFinalization();
if (command === "complete") await completeFinalization();
if (command === "fail") await failFinalization();

async function stageReview() {
  const results = readJson("results/grading-results.json");
  const students = readJson("results/students.json");
  const items = readJson("results/image-audit/review-items.json");
  if (!Array.isArray(results) || !results.length) throw new Error("No grading results were produced.");
  if (!Array.isArray(students) || !students.length) throw new Error("No trusted students were selected.");
  if (!Array.isArray(items)) throw new Error("The review queue is invalid.");

  const trusted = new Map(students.map((student) => [String(student.github_username).trim().toLowerCase(), student]));
  const stagedResults = results.map((result) => {
    const student = trusted.get(String(result.github_username).trim().toLowerCase());
    if (!student || student.firebase_uid !== result.firebase_uid || student.enrollment_path !== result.enrollment_path) {
      throw new Error(`Untrusted result for ${result.github_username}.`);
    }
    const key = resultKey(result);
    if (!key || key !== student.enrollment_id) throw new Error(`Enrollment mismatch for ${result.github_username}.`);
    return { key, result, student };
  });
  const resultIds = new Set(stagedResults.map(({ key }) => key));
  for (const item of items) {
    if (!String(item.id || "").match(/^[a-f0-9]{32}$/) || !resultIds.has(resultKey(item))) throw new Error("A review item is not linked to a trusted result.");
    if (!Number.isFinite(Number(item.automatic_points)) || !Number.isFinite(Number(item.max_points)) || Number(item.automatic_points) < 0 || Number(item.max_points) <= 0 || Number(item.automatic_points) > Number(item.max_points)) {
      throw new Error(`Invalid review points for ${item.expected_filename || item.id}.`);
    }
  }

  const existing = await runRef.get();
  if (existing.exists && existing.data().status !== "staging") throw new Error(`Grading run ${gradingRunId} has already been staged.`);

  const repository = String(process.env.GITHUB_REPOSITORY || "WaqasSaleem97/CC-Autograder");
  const server = String(process.env.GITHUB_SERVER_URL || "https://github.com");
  const status = items.length ? "reviewing" : "ready";
  const config = {
    courseCode: String(process.env.COURSE_ID || "").trim(),
    repositoryName: String(process.env.REPOSITORY_NAME || "").trim(),
    category: String(process.env.CATEGORY || "").trim(),
    assessment: String(process.env.ASSESSMENT_NAME || "").trim(),
    submissionPath: String(process.env.SUBMISSION_PATH || "").trim(),
    totalMarks: Number(process.env.TOTAL_MARKS),
    branch: String(process.env.BRANCH || "").trim(),
    testScript: String(process.env.TEST_SCRIPT || "staged/manual-review")
  };
  if (!config.courseCode || !config.repositoryName || !config.category || !config.assessment || !config.submissionPath || !Number.isFinite(config.totalMarks)) {
    throw new Error("The staged grading configuration is incomplete.");
  }

  await runRef.set({
    schema_version: 1,
    run_id: gradingRunId,
    status: "staging",
    course_code: config.courseCode,
    category: config.category,
    assessment: config.assessment,
    repository_name: config.repositoryName,
    submission_path: config.submissionPath,
    section: String(process.env.SECTION || "Both"),
    config,
    student_count: stagedResults.length,
    item_count: items.length,
    pending_count: items.length,
    reviewed_count: 0,
    requested_update_firestore: envBoolean("UPDATE_FIRESTORE"),
    requested_send_email: envBoolean("SEND_EMAIL_RESULTS"),
    source_run_number: String(process.env.GITHUB_RUN_NUMBER || ""),
    source_run_attempt: String(process.env.GITHUB_RUN_ATTEMPT || ""),
    source_workflow_url: `${server}/${repository}/actions/runs/${gradingRunId}`,
    finalization_workflow_url: `${server}/${repository}/actions/workflows/finalize-review.yml`,
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp()
  });

  await writeDocuments(stagedResults.map(({ key, result, student }) => ({
    ref: runRef.collection("results").doc(key),
    data: { enrollment_id: key, result, student, created_at: FieldValue.serverTimestamp() }
  })));
  await writeDocuments(items.map((item) => ({
    ref: runRef.collection("items").doc(item.id),
    data: { ...item, decision: "pending", reviewer_note: "", reviewed_at: null, reviewer_uid: "", created_at: FieldValue.serverTimestamp() }
  })));
  await runRef.update({ status, updated_at: FieldValue.serverTimestamp() });

  summary(`Staged grading run ${gradingRunId}: ${stagedResults.length} students and ${items.length} suspicious screenshot(s). Status: ${status}.`);
}

async function prepareFinalization() {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(runRef);
    if (!snapshot.exists) throw new Error(`Grading run ${gradingRunId} was not found.`);
    const data = snapshot.data();
    if (data.status === "finalized") throw new Error("This grading run has already been finalized.");
    if (!["ready", "finalization_failed", "finalizing"].includes(data.status)) throw new Error("Complete every manual-review decision in the portal before finalizing.");
    transaction.update(runRef, {
      status: "finalizing",
      finalization_source_run_id: String(process.env.GITHUB_RUN_ID || ""),
      finalization_started_at: FieldValue.serverTimestamp(),
      finalization_error: FieldValue.delete(),
      updated_at: FieldValue.serverTimestamp()
    });
  });

  const [runSnapshot, resultSnapshot, itemSnapshot] = await Promise.all([
    runRef.get(),
    runRef.collection("results").get(),
    runRef.collection("items").get()
  ]);
  const run = runSnapshot.data();
  const staged = resultSnapshot.docs.map((snapshot) => snapshot.data());
  const items = itemSnapshot.docs.map((snapshot) => ({ id: snapshot.id, ...snapshot.data() }));
  if (items.length !== Number(run.item_count || 0)) throw new Error("The staged review queue is incomplete.");
  const results = applyReviewDecisions(staged.map((entry) => entry.result), items);
  const students = staged.map((entry) => entry.student);

  mkdirSync(path.join(root, "results"), { recursive: true });
  mkdirSync(path.join(root, "config"), { recursive: true });
  writeFileSync(path.join(root, "results/grading-results.json"), `${JSON.stringify(results, null, 2)}\n`);
  writeFileSync(path.join(root, "results/students.json"), `${JSON.stringify(students, null, 2)}\n`);
  writeFileSync(path.join(root, "config/assignment.json"), `${JSON.stringify(run.config, null, 2)}\n`);
  output("update_firestore", Boolean(run.requested_update_firestore));
  output("send_email_results", Boolean(run.requested_send_email));
  output("student_count", results.length);
  summary(`Prepared ${results.length} final result(s) from grading run ${gradingRunId}. All ${items.length} review decision(s) are resolved.`);
}

async function completeFinalization() {
  const snapshot = await runRef.get();
  if (!snapshot.exists) throw new Error(`Grading run ${gradingRunId} was not found.`);
  await runRef.update({
    status: "finalized",
    pending_count: 0,
    reviewed_count: Number(snapshot.data().item_count || 0),
    marks_published: envBoolean("MARKS_PUBLISHED"),
    email_results_sent: envBoolean("EMAIL_RESULTS_SENT"),
    finalized_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp()
  });
  summary(`Grading run ${gradingRunId} is finalized.`);
}

async function failFinalization() {
  const snapshot = await runRef.get();
  if (!snapshot.exists || snapshot.data().status === "finalized") return;
  await runRef.update({
    status: "finalization_failed",
    finalization_error: String(process.env.FINALIZATION_ERROR || "The finalization workflow failed. Review its GitHub Actions log and retry.").slice(0, 1000),
    updated_at: FieldValue.serverTimestamp()
  });
}

async function writeDocuments(entries) {
  for (let start = 0; start < entries.length; start += 400) {
    const batch = db.batch();
    for (const entry of entries.slice(start, start + 400)) batch.set(entry.ref, entry.data);
    await batch.commit();
  }
}

function output(name, value) {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
}

function summary(message) {
  console.log(message);
  if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `${message}\n`);
}
