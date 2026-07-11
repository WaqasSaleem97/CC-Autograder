import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync, readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

function normalizeGithubUsername(value = "") {
  return value
    .trim()
    .replace(/^https?:\/\/(?:www\.)?github\.com\//i, "")
    .replace(/^@/, "")
    .replace(/\/$/, "");
}

const rawUsername = argument("--github-user") || process.env.STUDENT_GITHUB_USERNAME || "";
const username = normalizeGithubUsername(rawUsername);

if (!username || !/^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$/i.test(username)) {
  throw new Error(
    `Invalid GitHub username: ${rawUsername ? JSON.stringify(rawUsername) : "empty value"}. ` +
    "Enter username, @username, or https://github.com/username."
  );
}

if (!/^[A-Za-z0-9._-]+$/.test(config.repositoryName)) {
  throw new Error("repositoryName contains unsupported characters.");
}

const submissionsRoot = path.join(root, "work", "submissions");
const destination = path.join(submissionsRoot, username, config.repositoryName);
const repositoryUrl = `https://github.com/${username}/${config.repositoryName}.git`;

mkdirSync(path.dirname(destination), { recursive: true });
rmSync(destination, { recursive: true, force: true });

console.log(`Cloning ${repositoryUrl}`);

try {
  execFileSync("git", [
    "clone",
    "--depth", "1",
    "--branch", config.branch,
    "--config", "credential.helper=",
    repositoryUrl,
    destination
  ], { stdio: "inherit", timeout: 120_000 });
} catch {
  throw new Error(`Unable to clone ${repositoryUrl}. Confirm that the repository exists and is public.`);
}

const submissionDirectory = path.join(destination, ...config.submissionPath.split("/"));

if (!existsSync(submissionDirectory)) {
  console.warn(`Required directory is missing: ${config.submissionPath}`);
} else {
  console.log(`Submission collected: ${submissionDirectory}`);
}
