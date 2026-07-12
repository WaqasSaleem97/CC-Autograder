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
  const args = [];
  if (process.env.GH_TOKEN) args.push("-c", `http.extraheader=AUTHORIZATION: basic ${Buffer.from(`x-access-token:${process.env.GH_TOKEN}`).toString("base64")}`);
  args.push("clone", "--depth", "1", "--branch", config.branch, "--config", "credential.helper=", url, destination);
  console.log(`Cloning ${username}/${config.repositoryName}`);
  try {
    execFileSync("git", args, { stdio: "inherit", timeout: 120_000 });
    const submission = path.join(destination, ...config.submissionPath.split("/"));
    console.log(existsSync(submission) ? `${username}: submission collected.` : `${username}: directory missing: ${config.submissionPath}`);
    collected++;
  } catch (error) { console.error(`${username}: repository could not be collected (${error.message}).`); }
}
console.log(`Collection complete: ${collected}/${students.length} repositories cloned.`);

