import { readFileSync } from "node:fs";
const results = JSON.parse(readFileSync("results/grading-results.json", "utf8"));
console.log(`Grading completed for ${results.length} students`);
results.forEach((r) => console.log(`${r.registration_number} | ${r.github_username}: ${r.obtained}/${r.total} - ${r.feedback}`));

