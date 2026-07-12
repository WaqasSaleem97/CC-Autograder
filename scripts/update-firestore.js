import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = process.env.FIREBASE_PROJECT_ID;
const assignment = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));
if (!projectId) throw new Error("FIREBASE_PROJECT_ID repository variable is required.");

initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
const results = JSON.parse(readFileSync(path.join(root, "results/grading-results.json"), "utf8"));
const students = JSON.parse(readFileSync(path.join(root, "results/students.json"), "utf8"));
if (!Array.isArray(results) || results.length === 0) throw new Error("No grading results were found.");
if (!Array.isArray(students)) throw new Error("Invalid students.json.");

const trustedStudents = new Map(students.map((student) => [
  String(student.github_username || "").toLowerCase(), student
]));

function validateResult(result) {
  const student = trustedStudents.get(String(result.github_username || "").toLowerCase());
  if (!student) throw new Error(`Untrusted student result: ${result.github_username}.`);
  if (String(result.firebase_uid) !== String(student.firebase_uid)) throw new Error("Firebase UID mismatch.");
  if (String(result.enrollment_path) !== String(student.enrollment_path)) throw new Error("Enrollment path mismatch.");
  if (String(result.course_code).toLowerCase() !== String(assignment.courseCode).toLowerCase()) throw new Error("Course mismatch.");
  if (String(result.category).toLowerCase() !== String(assignment.category).toLowerCase()) throw new Error("Category mismatch.");
  if (String(result.assessment).toLowerCase() !== String(assignment.assessment).toLowerCase()) throw new Error("Assessment mismatch.");
  if (result.repository.toLowerCase() !== `${student.github_username}/${assignment.repositoryName}`.toLowerCase()) throw new Error("Repository mismatch.");
  if (!Number.isFinite(result.obtained) || !Number.isFinite(result.total) ||
      result.obtained < 0 || result.total !== Number(assignment.totalMarks) || result.obtained > result.total) {
    throw new Error(`Invalid marks for ${result.github_username}.`);
  }
  return student;
}

for (const result of results) {
  const student = validateResult(result);
  const enrollmentRef = db.doc(student.enrollment_path);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(enrollmentRef);
    if (!snapshot.exists) throw new Error(`Enrollment no longer exists: ${student.enrollment_path}`);
    const enrollment = snapshot.data();
    if (enrollment.approved !== true) throw new Error(`${result.github_username} is no longer approved.`);
    const enrollmentCourse = String(enrollment.course_code || enrollment.course_id || "").toLowerCase();
    if (enrollmentCourse !== String(assignment.courseCode).toLowerCase()) throw new Error("Enrollment course changed.");

    const categories = Array.isArray(enrollment?.marks?.categories)
      ? structuredClone(enrollment.marks.categories) : [];
    let category = categories.find((item) =>
      String(item.name || "").toLowerCase() === result.category.toLowerCase());
    if (!category) {
      category = { name: result.category, items: [] };
      categories.push(category);
    }
    if (!Array.isArray(category.items)) category.items = [];
    const existingItem = category.items.find((item) =>
      String(item.name || "").toLowerCase() === result.assessment.toLowerCase());
    const marks = {
      name: result.assessment,
      obtained: result.obtained,
      total: result.total,
      feedback: result.feedback,
      repository: result.repository,
      graded_at: result.graded_at
    };
    if (existingItem) Object.assign(existingItem, marks);
    else category.items.push(marks);
    transaction.update(enrollmentRef, {
      marks: { categories },
      updated_at: FieldValue.serverTimestamp()
    });
  });
  console.log(`Firestore updated for ${result.github_username}: ${result.category}/${result.assessment} = ${result.obtained}/${result.total}`);
}

console.log(`Firestore update complete for ${results.length} students.`);
