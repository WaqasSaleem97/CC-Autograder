import { readFileSync } from "node:fs";
const results = JSON.parse(readFileSync("results/grading-results.json", "utf8"));
console.log(`Grading completed for ${results.length} students`);
results.forEach((r) => {
  const outcome = r.status === "error" ? "NOT GRADED" : `${r.obtained}/${r.total}`;
  console.log(`${r.registration_number} | ${r.github_username}: ${outcome} - ${r.feedback}`);
});
