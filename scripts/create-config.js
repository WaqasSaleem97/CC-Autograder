import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const value = (name) => String(process.env[name] || "").trim();
const safePath = (input) => input && !path.isAbsolute(input) && !input.split(/[\\/]+/).includes("..");

const config = {
  courseCode: value("COURSE_ID"),
  repositoryName: value("REPOSITORY_NAME"),
  category: value("CATEGORY"),
  assessment: value("ASSESSMENT_NAME"),
  submissionPath: value("SUBMISSION_PATH").replaceAll("\\", "/").replace(/^\.\//, "").replace(/\/$/, ""),
  testScript: value("TEST_SCRIPT").replaceAll("\\", "/").replace(/^\.\//, ""),
  totalMarks: Number(value("TOTAL_MARKS")),
  branch: value("BRANCH")
};

for (const field of ["courseCode", "repositoryName", "category", "assessment", "submissionPath", "testScript", "branch"]) {
  if (!config[field]) throw new Error(`${field} is required.`);
}
if (!/^[A-Za-z0-9._-]+$/.test(config.repositoryName)) throw new Error("Invalid repository name.");
if (!/^[A-Za-z0-9._\/-]+$/.test(config.branch)) throw new Error("Invalid branch name.");
if (!safePath(config.submissionPath)) throw new Error("submissionPath must be a safe relative path.");
if (!safePath(config.testScript) || !config.testScript.startsWith("tests/") || !config.testScript.endsWith(".sh")) throw new Error("testScript must be a .sh file below tests/.");
const resolvedTest = path.resolve(root, config.testScript);
if (!resolvedTest.startsWith(path.join(root, "tests") + path.sep) || !existsSync(resolvedTest)) throw new Error(`Trusted test script does not exist: ${config.testScript}`);
if (!Number.isFinite(config.totalMarks) || config.totalMarks <= 0) throw new Error("totalMarks must be greater than zero.");

mkdirSync(path.join(root, "config"), { recursive: true });
writeFileSync(path.join(root, "config/assignment.json"), `${JSON.stringify(config, null, 2)}\n`);
console.log(`Configuration: ${config.courseCode} | ${config.category}/${config.assessment} | ${config.submissionPath} | ${config.totalMarks} marks`);

