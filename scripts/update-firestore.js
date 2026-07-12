import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = process.env.FIREBASE_PROJECT_ID;
const config = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
const results = JSON.parse(readFileSync(path.join(root, "results/grading-results.json"), "utf8"));
const students = JSON.parse(readFileSync(path.join(root, "results/students.json"), "utf8"));
if (!projectId) throw new Error("FIREBASE_PROJECT_ID is required.");
if (!Array.isArray(results) || !results.length) throw new Error("No grading results found.");
initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
const trusted = new Map(students.map((s) => [String(s.github_username).toLowerCase(), s]));

for (const result of results) {
  const student = trusted.get(String(result.github_username).toLowerCase());
  if (!student || result.firebase_uid !== student.firebase_uid || result.enrollment_path !== student.enrollment_path) throw new Error(`Untrusted result for ${result.github_username}.`);
  if (String(result.course_code).toLowerCase() !== config.courseCode.toLowerCase() || result.category !== config.category || result.assessment !== config.assessment) throw new Error(`Configuration mismatch for ${result.github_username}.`);
  if (result.repository.toLowerCase() !== `${student.github_username}/${config.repositoryName}`.toLowerCase()) throw new Error("Repository mismatch.");
  if (!Number.isFinite(result.obtained) || result.obtained < 0 || result.total !== config.totalMarks || result.obtained > result.total) throw new Error("Invalid marks.");
  const ref = db.doc(student.enrollment_path);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists || snapshot.data().approved !== true) throw new Error(`${student.registration_number} is no longer approved.`);
    const enrollment = snapshot.data();
    const values = [enrollment.course_id, enrollment.course_code].map((v) => String(v || "").toLowerCase());
    if (!values.includes(config.courseCode.toLowerCase())) throw new Error("Enrollment course changed.");
    const categories = Array.isArray(enrollment?.marks?.categories) ? structuredClone(enrollment.marks.categories) : [];
    let category = categories.find((c) => String(c.name).toLowerCase() === config.category.toLowerCase());
    if (!category) { category = { name: config.category, items: [] }; categories.push(category); }
    if (!Array.isArray(category.items)) category.items = [];
    const marks = { name: config.assessment, obtained: result.obtained, total: result.total, feedback: result.feedback, repository: result.repository, graded_at: result.graded_at };
    const existing = category.items.find((item) => String(item.name).toLowerCase() === config.assessment.toLowerCase());
    if (existing) Object.assign(existing, marks); else category.items.push(marks);
    transaction.update(ref, { marks: { categories }, updated_at: FieldValue.serverTimestamp() });
  });
  console.log(`Updated ${student.registration_number}: ${config.category}/${config.assessment} = ${result.obtained}/${result.total}`);
}

