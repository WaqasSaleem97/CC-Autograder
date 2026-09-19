import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
const argument = (name) => { const index = process.argv.indexOf(name); return index >= 0 ? process.argv[index + 1] : undefined; };
const students = JSON.parse(readFileSync(path.resolve(root, argument("--students-file") || "results/students.json"), "utf8"));
if (!Array.isArray(students) || !students.length) throw new Error("Student list is empty.");

let collected = 0;
for (const student of students) {
  const username = String(student.github_username || "").trim();
  const destination = path.join(root, "work/submissions", username, config.repositoryName);
  const url = `https://github.com/${username}/${config.repositoryName}.git`;
  mkdirSync(path.dirname(destination), { recursive: true });
  rmSync(destination, { recursive: true, force: true });
  const authentication = [];
  if (process.env.GH_TOKEN) authentication.push("-c", `http.extraheader=AUTHORIZATION: basic ${Buffer.from(`x-access-token:${process.env.GH_TOKEN}`).toString("base64")}`);
  const clone = (branch) => {
    const args = [...authentication, "clone", "--depth", "1"];
    if (branch) args.push("--branch", branch);
    args.push("--config", "credential.helper=", url, destination);
    return execFileSync("git", args, { stdio: ["ignore", "inherit", "pipe"], timeout: 120_000 });
  };
  console.log(`Cloning ${username}/${config.repositoryName}`);
  try {
    try {
      clone(config.branch);
    } catch (error) {
      const stderr = String(error.stderr || "");
      process.stderr.write(stderr);
      if (!/Remote branch .* not found in upstream origin/i.test(stderr)) throw error;
      console.warn(`${username}: branch ${config.branch} was not found; retrying the repository's default branch.`);
      rmSync(destination, { recursive: true, force: true });
      clone("");
    }
    const submission = path.join(destination, ...config.submissionPath.split("/"));
    console.log(existsSync(submission) ? `${username}: submission collected.` : `${username}: directory missing: ${config.submissionPath}`);
    collected++;
  } catch {
    const tokenHint = process.env.GH_TOKEN ? "" : " Configure STUDENT_REPOS_TOKEN if this repository is private.";
    console.error(`${username}: repository could not be collected.${tokenHint}`);
    rmSync(destination, { recursive: true, force: true });
  }
}
console.log(`Collection complete: ${collected}/${students.length} repositories cloned.`);
