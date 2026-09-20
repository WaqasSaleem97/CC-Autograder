import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { normalizeScreenshotFilenames } from "./screenshot-normalization.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
const argument = (name) => { const index = process.argv.indexOf(name); return index >= 0 ? process.argv[index + 1] : undefined; };
const students = JSON.parse(readFileSync(path.resolve(root, argument("--students-file") || "results/students.json"), "utf8"));
const testScript = path.resolve(root, config.testScript);
const results = [];
const preparationErrors = new Map();

// Normalize every collected repository before the first student is graded so
// duplicate detection sees the same case-insensitive filenames for everyone.
// These are disposable workflow clones; students' GitHub repositories are not
// modified.
for (const student of students) {
  const username = student.github_username;
  const repository = path.join(root, "work/submissions", username, config.repositoryName);
  const submission = path.join(repository, ...config.submissionPath.split("/"));
  const screenshots = path.join(submission, "screenshots");
  if (!existsSync(screenshots)) continue;
  try {
    normalizeScreenshotFilenames(screenshots);
  } catch (error) {
    preparationErrors.set(username, error);
  }
}

for (const student of students) {
  const username = student.github_username;
  const normalizedUsername = String(username || "").trim().toLowerCase();
  const repository = path.join(root, "work/submissions", username, config.repositoryName);
  const submission = path.join(repository, ...config.submissionPath.split("/"));
  let testResult;
  let status = "graded";
  if (preparationErrors.has(username)) {
    status = "error";
    testResult = { score: null, feedback: `Screenshot filename normalization failed; marks were not changed: ${preparationErrors.get(username).message}` };
  }
  else if (!existsSync(repository)) {
    status = "error";
    testResult = { score: null, feedback: "Repository could not be collected; marks were not changed." };
  }
  else if (!existsSync(submission)) testResult = { score: 0, feedback: `Required directory is missing: ${config.submissionPath}` };
  else {
    try {
      const output = execFileSync("bash", [testScript, submission, String(config.totalMarks), normalizedUsername], {
        cwd: root, encoding: "utf8", timeout: 600_000,
        env: {
          PATH: process.env.PATH,
          HOME: process.env.HOME || "/tmp",
          LANG: "C.UTF-8",
          OCR_JOBS: process.env.OCR_JOBS || "4",
          OMP_THREAD_LIMIT: process.env.OMP_THREAD_LIMIT || "1"
        }
      }).trim();
      testResult = JSON.parse(output.split(/\r?\n/).at(-1));
    } catch (error) {
      status = "error";
      testResult = { score: null, feedback: `Grading test failed; marks were not changed: ${error.message}` };
    }
  }
  const total = Number(config.totalMarks);
  const obtained = status === "graded" ? Number(testResult.score) : null;
  const reviewCount = status === "graded" ? Number(testResult.review_count || 0) : 0;
  if (status === "graded" && (!Number.isFinite(obtained) || obtained < 0 || obtained > total)) throw new Error(`Invalid score for ${username}: ${obtained}/${total}`);
  if (!Number.isInteger(reviewCount) || reviewCount < 0) throw new Error(`Invalid manual-review count for ${username}: ${testResult.review_count}`);
  results.push({ firebase_uid: student.firebase_uid, enrollment_path: student.enrollment_path, registration_number: student.registration_number, github_username: username, course_code: config.courseCode, category: config.category, assessment: config.assessment, status, obtained, total, review_required: reviewCount > 0, review_count: reviewCount, feedback: String(testResult.feedback || ""), repository: `${username}/${config.repositoryName}`, submission_path: config.submissionPath, graded_at: new Date().toISOString() });
}
mkdirSync(path.join(root, "results"), { recursive: true });
writeFileSync(path.join(root, "results/grading-results.json"), `${JSON.stringify(results, null, 2)}\n`);
console.log(`Generated ${results.length} grading results.`);
