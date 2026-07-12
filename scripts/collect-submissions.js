import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function normalizeGithubUsername(value = "") {
  return String(value).trim().replace(/^https?:\/\/(?:www\.)?github\.com\//i, "")
    .replace(/^@/, "").replace(/\/$/, "");
}

function validUsername(username) {
  return /^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/i.test(username);
}

function loadStudents() {
  const studentsFile = argument("--students-file");
  if (studentsFile) {
    const absolutePath = path.resolve(root, studentsFile);
    const students = JSON.parse(readFileSync(absolutePath, "utf8"));
    if (!Array.isArray(students) || students.length === 0) {
      throw new Error("The students file must contain at least one student.");
    }
    return students;
  }

  const username = normalizeGithubUsername(
    argument("--github-user") || process.env.STUDENT_GITHUB_USERNAME || ""
  );
  if (!validUsername(username)) {
    throw new Error("Provide --students-file or a valid --github-user.");
  }
  return [{ github_username: username }];
}

if (!/^[A-Za-z0-9._-]+$/.test(config.repositoryName)) {
  throw new Error("repositoryName contains unsupported characters.");
}

const students = loadStudents();
const submissionsRoot = path.join(root, "work", "submissions");
mkdirSync(submissionsRoot, { recursive: true });

let collected = 0;
let failed = 0;

for (const student of students) {
  const username = normalizeGithubUsername(student.github_username || student.user_name || "");
  if (!validUsername(username)) {
    console.error(`Skipping invalid GitHub username: ${JSON.stringify(username)}`);
    failed += 1;
    continue;
  }

  const destination = path.join(submissionsRoot, username, config.repositoryName);
  const repositoryUrl = `https://github.com/${username}/${config.repositoryName}.git`;
  mkdirSync(path.dirname(destination), { recursive: true });
  rmSync(destination, { recursive: true, force: true });

  const gitArguments = [];
  if (process.env.GH_TOKEN) {
    const basic = Buffer.from(`x-access-token:${process.env.GH_TOKEN}`).toString("base64");
    gitArguments.push("-c", `http.extraheader=AUTHORIZATION: basic ${basic}`);
  }
  gitArguments.push(
    "clone", "--depth", "1", "--branch", config.branch,
    "--config", "credential.helper=", repositoryUrl, destination
  );

  console.log(`Cloning ${username}/${config.repositoryName}`);
  try {
    execFileSync("git", gitArguments, { stdio: "inherit", timeout: 120_000 });
    const submissionDirectory = path.join(destination, ...config.submissionPath.split("/"));
    if (!existsSync(submissionDirectory)) {
      console.warn(`${username}: required directory is missing: ${config.submissionPath}`);
    } else {
      console.log(`${username}: submission collected.`);
    }
    collected += 1;
  } catch (error) {
    console.error(`${username}: repository could not be cloned (${error.message}).`);
    failed += 1;
  }
}

console.log(`Collection complete: ${collected} cloned, ${failed} failed.`);

