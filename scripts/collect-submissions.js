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

const username = argument("--github-user");

if (!username || !/^[a-zd](?:[a-zd-]{0,37}[a-zd])?$/i.test(username)) {
  throw new Error("Provide a valid GitHub username with --github-user.");
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
