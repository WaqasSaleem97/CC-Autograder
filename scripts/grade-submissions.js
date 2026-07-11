import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const username = argument("--github-user");
if (!username) throw new Error("Provide --github-user.");

const repositoryDirectory = path.join(root, "work", "submissions", username, config.repositoryName);
const submissionDirectory = path.join(repositoryDirectory, ...config.submissionPath.split("/"));
const testScript = path.join(root, config.testScript);

let testResult;

try {
  const output = execFileSync("bash", [testScript, submissionDirectory, config.expectedOutput], {
    cwd: root,
    encoding: "utf8",
    timeout: 60_000,
    env: { PATH: process.env.PATH, HOME: process.env.HOME || "/tmp" }
  }).trim();

  testResult = JSON.parse(output.split(/\r?\n/).at(-1));
} catch (error) {
  testResult = {
    score: 0,
    feedback: `Grading test failed safely: ${error.message}`
  };
}

const obtained = Number(testResult.score);
const total = Number(config.totalMarks);

if (!Number.isFinite(obtained) || !Number.isFinite(total) || obtained < 0 || obtained > total) {
  throw new Error(`Invalid grading result: ${obtained}/${total}`);
}

const result = {
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
};

const resultsDirectory = path.join(root, "results");
mkdirSync(resultsDirectory, { recursive: true });
writeFileSync(path.join(resultsDirectory, "grading-results.json"), `${JSON.stringify([result], null, 2)}\n`);

console.log(`Generated score: ${obtained}/${total}`);
