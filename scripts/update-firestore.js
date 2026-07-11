import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectId = process.env.FIREBASE_PROJECT_ID;
const expectedUsername = process.env.EXPECTED_GITHUB_USERNAME;
const assignment = JSON.parse(readFileSync(path.join(root, "config/assignment.json"), "utf8"));

if (!projectId) throw new Error("FIREBASE_PROJECT_ID repository variable is required.");
if (!expectedUsername) throw new Error("EXPECTED_GITHUB_USERNAME is required.");

initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();

const results = JSON.parse(readFileSync(path.join(root, "results/grading-results.json"), "utf8"));

if (!Array.isArray(results) || results.length !== 1) {
  throw new Error("Expected exactly one grading result.");
}

function validateResult(result) {
  const requiredStrings = ["github_username", "course_code", "category", "assessment"];
  for (const field of requiredStrings) {
    if (typeof result[field] !== "string" || !result[field].trim()) throw new Error(`Invalid ${field}.`);
  }

  if (!Number.isFinite(result.obtained) || !Number.isFinite(result.total)) throw new Error("Marks must be numeric.");
  if (result.obtained < 0 || result.total <= 0 || result.obtained > result.total) throw new Error("Marks are outside the permitted range.");

  const expected = {
    github_username: expectedUsername,
    course_code: assignment.courseCode,
    category: assignment.category,
    assessment: assignment.assessment,
    total: Number(assignment.totalMarks),
    repository: `${expectedUsername}/${assignment.repositoryName}`
  };

  for (const field of ["github_username", "course_code", "category", "assessment", "repository"]) {
    if (String(result[field]).toLowerCase() !== String(expected[field]).toLowerCase()) {
      throw new Error(`Result ${field} does not match the trusted workflow configuration.`);
    }
  }

  if (result.total !== expected.total) throw new Error("Result total does not match the trusted assignment configuration.");
}

for (const result of results) {
  validateResult(result);

  // GitHub usernames are case-insensitive, while a Firestore equality query is not.
  // The class is small, so reading profiles and comparing normalized names is reliable.
  const usersSnapshot = await db.collection("users").get();
  const matchingUsers = usersSnapshot.docs.filter((userDoc) =>
    String(userDoc.data().user_name || "").toLowerCase() === result.github_username.toLowerCase()
  );

  if (matchingUsers.length !== 1) {
    throw new Error(`Expected one portal user for GitHub username ${result.github_username}; found ${matchingUsers.length}.`);
  }

  const userId = matchingUsers[0].id;
  const enrollmentsSnapshot = await db.collection("enrollments").where("user_id", "==", userId).get();
  const matchingEnrollments = enrollmentsSnapshot.docs.filter((enrollmentDoc) => {
    const enrollment = enrollmentDoc.data();
    return enrollment.approved === true &&
      String(enrollment.course_code || "").toLowerCase() === result.course_code.toLowerCase();
  });

  if (matchingEnrollments.length !== 1) {
    throw new Error(`Expected one approved ${result.course_code} enrollment for ${result.github_username}; found ${matchingEnrollments.length}.`);
  }

  const enrollmentRef = matchingEnrollments[0].ref;

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(enrollmentRef);
    const enrollment = snapshot.data();
    const categories = Array.isArray(enrollment?.marks?.categories)
      ? structuredClone(enrollment.marks.categories)
      : [];

    let category = categories.find((item) =>
      String(item.name || "").toLowerCase() === result.category.toLowerCase()
    );

    if (!category) {
      category = { name: result.category, items: [] };
      categories.push(category);
    }

    if (!Array.isArray(category.items)) category.items = [];

    const existingItem = category.items.find((item) =>
      String(item.name || "").toLowerCase() === result.assessment.toLowerCase()
    );

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
