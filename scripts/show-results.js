import { readFileSync } from "node:fs";
const results = JSON.parse(readFileSync("results/grading-results.json", "utf8"));
const notGraded = results.filter((result) => result.status === "error").length;
console.log(`Grading completed: ${results.length - notGraded}/${results.length} graded, ${notGraded} not graded.`);
if (notGraded && process.env.GITHUB_ACTIONS === "true") {
  console.log(`::warning title=Incomplete grading::${notGraded} of ${results.length} submissions were not graded. Check the NOT GRADED rows. Existing marks for those submissions were not changed.`);
}
results.forEach((r) => {
  const outcome = r.status === "error" ? "NOT GRADED" : `${r.obtained}/${r.total}`;
  const review = r.review_required ? ` | MANUAL REVIEW: ${r.review_count} check(s)` : "";
  console.log(`${r.registration_number} | ${r.github_username}: ${outcome}${review} - ${r.feedback}`);
});

