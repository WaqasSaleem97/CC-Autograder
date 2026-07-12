import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function loadStudents() {
  const studentsFile = argument("--students-file");
  if (studentsFile) {
    const students = JSON.parse(readFileSync(path.resolve(root, studentsFile), "utf8"));
    if (!Array.isArray(students) || students.length === 0) throw new Error("Students file is empty.");
    return students;
  }
  const username = argument("--github-user") || process.env.STUDENT_GITHUB_USERNAME || "";
  if (!username.trim()) throw new Error("Provide --students-file or --github-user.");
  return [{ github_username: username.trim() }];
}

const requestedAssessment = argument("--assessment");
if (requestedAssessment) {
  const normalize = (value) => String(value).replace(/[^a-z0-9]/gi, "").toLowerCase();
  if (normalize(requestedAssessment) !== normalize(config.assessment)) {
    throw new Error(`Requested assessment ${requestedAssessment} does not match ${config.assessment}.`);
  }
}

const students = loadStudents();
const testScript = path.join(root, config.testScript);
const results = [];

for (const student of students) {
  const username = String(student.github_username || "").trim();
  const repositoryDirectory = path.join(root, "work", "submissions", username, config.repositoryName);
  const submissionDirectory = path.join(repositoryDirectory, ...config.submissionPath.split("/"));
  let testResult;

  if (!existsSync(repositoryDirectory)) {
    testResult = { score: 0, feedback: "Repository could not be collected." };
  } else if (!existsSync(submissionDirectory)) {
    testResult = { score: 0, feedback: `Required directory is missing: ${config.submissionPath}` };
  } else {
    try {
      const output = execFileSync("bash", [testScript, submissionDirectory, config.expectedOutput], {
        cwd: root,
        encoding: "utf8",
        timeout: 60_000,
        env: { PATH: process.env.PATH, HOME: process.env.HOME || "/tmp" }
      }).trim();
      testResult = JSON.parse(output.split(/\r?\n/).at(-1));
    } catch (error) {
      testResult = { score: 0, feedback: `Grading test failed safely: ${error.message}` };
    }
  }

  const obtained = Number(testResult.score);
  const total = Number(config.totalMarks);
  if (!Number.isFinite(obtained) || !Number.isFinite(total) || obtained < 0 || obtained > total) {
    throw new Error(`Invalid grading result for ${username}: ${obtained}/${total}`);
  }

  results.push({
    firebase_uid: String(student.firebase_uid || ""),
    enrollment_path: String(student.enrollment_path || ""),
    registration_number: String(student.registration_number || ""),
    github_username: username,
    course_code: config.courseCode,
    category: config.category,
    assessment: config.assessment,
    obtained,
    total,
    feedback: String(testResult.feedback || ""),
    repository: `${username}/${config.repositoryName}`,
    submission_path: config.submissionPath,
    graded_at: new Date().toISOString()
  });
  console.log(`${username}: ${obtained}/${total} - ${testResult.feedback || ""}`);
}

const resultsDirectory = path.join(root, "results");
mkdirSync(resultsDirectory, { recursive: true });
writeFileSync(path.join(resultsDirectory, "grading-results.json"), `${JSON.stringify(results, null, 2)}\n`);
console.log(`Generated ${results.length} grading results.`);

