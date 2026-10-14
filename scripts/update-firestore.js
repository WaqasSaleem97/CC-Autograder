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
let updated = 0;
let skipped = 0;
const cleanMarkName = (value) => String(value || "").trim().replace(/\s+/g, " ");
const markNameKey = (value) => cleanMarkName(value).toLowerCase();
const mergeCategories = (...marksSources) => {
  const merged = new Map();
  marksSources.flatMap((marks) => Array.isArray(marks?.categories) ? marks.categories : []).forEach((sourceCategory) => {
    const name = cleanMarkName(sourceCategory?.name); const key = markNameKey(name); if (!key) return;
    if (!merged.has(key)) merged.set(key, { ...sourceCategory, name, items: [] });
    const category = merged.get(key); const itemIndexes = new Map(category.items.map((item, index) => [markNameKey(item.name), index]));
    (Array.isArray(sourceCategory?.items) ? sourceCategory.items : []).forEach((sourceItem) => {
      const itemName = cleanMarkName(sourceItem?.name); const itemKey = markNameKey(itemName); if (!itemKey) return;
      const candidate = { ...sourceItem, name: itemName };
      if (!itemIndexes.has(itemKey)) { itemIndexes.set(itemKey, category.items.length); category.items.push(candidate); return; }
      const index = itemIndexes.get(itemKey); const existing = category.items[index];
      if ((Date.parse(candidate.graded_at || "") || 0) > (Date.parse(existing.graded_at || "") || 0)) category.items[index] = candidate;
    });
  });
  return [...merged.values()];
};

for (const result of results) {
  const student = trusted.get(String(result.github_username).toLowerCase());
  if (!student || result.firebase_uid !== student.firebase_uid || result.enrollment_path !== student.enrollment_path) throw new Error(`Untrusted result for ${result.github_username}.`);
  if (String(result.course_code).toLowerCase() !== config.courseCode.toLowerCase() || result.category !== config.category || result.assessment !== config.assessment) throw new Error(`Configuration mismatch for ${result.github_username}.`);
  if (result.repository.toLowerCase() !== `${student.github_username}/${config.repositoryName}`.toLowerCase()) throw new Error("Repository mismatch.");
  if (result.status === "error") {
    console.warn(`Skipped ${student.registration_number}: ${result.feedback}`);
    skipped++;
    continue;
  }
  if (result.status !== "graded") throw new Error(`Unknown grading status for ${result.github_username}.`);
  if (!Number.isFinite(result.obtained) || result.obtained < 0 || result.total !== config.totalMarks || result.obtained > result.total) throw new Error("Invalid marks.");
  const reviewCount = Number(result.review_count || 0);
  if (!Number.isInteger(reviewCount) || reviewCount < 0) throw new Error("Invalid manual-review count.");
  if (reviewCount > 0) {
    console.warn(`Skipped ${student.registration_number}: ${reviewCount} OCR/evidence check(s) require review, so provisional marks were not published.`);
    skipped++;
    continue;
  }
  const ref = db.doc(student.enrollment_path); const privateRef = db.collection("private_marks").doc(student.enrollment_id);
  let categoryHiddenFromStudents = false;
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists || snapshot.data().approved !== true) throw new Error(`${student.registration_number} is no longer approved.`);
    const enrollment = snapshot.data();
    const values = [enrollment.course_id, enrollment.course_code].map((v) => String(v || "").toLowerCase());
    if (!values.includes(config.courseCode.toLowerCase())) throw new Error("Enrollment course changed.");
    const privateSnapshot = await transaction.get(privateRef);
    const courseId = String(enrollment.course_id || "").trim(); const courseSnapshot = courseId ? await transaction.get(db.collection("courses").doc(courseId)) : null;
    const categories = mergeCategories(privateSnapshot.exists ? privateSnapshot.data()?.marks : null, enrollment.marks);
    const categoryKey = markNameKey(config.category); const matchingCategories = categories.filter((candidate) => markNameKey(candidate?.name) === categoryKey);
    let category;
    if (matchingCategories.length) {
      const matchingItems = matchingCategories.map((sourceCategory) => Array.isArray(sourceCategory?.items) ? structuredClone(sourceCategory.items) : []);
      category = matchingCategories[0]; category.name = cleanMarkName(config.category); category.items = [];
      const itemIndexes = new Map();
      matchingItems.forEach((sourceItems) => sourceItems.forEach((sourceItem) => {
        const itemKey = markNameKey(sourceItem?.name); if (!itemKey) return;
        const candidate = { ...sourceItem, name: cleanMarkName(sourceItem.name) };
        if (!itemIndexes.has(itemKey)) { itemIndexes.set(itemKey, category.items.length); category.items.push(candidate); return; }
        const index = itemIndexes.get(itemKey); const existingItem = category.items[index];
        if ((Date.parse(candidate.graded_at || "") || 0) > (Date.parse(existingItem.graded_at || "") || 0)) category.items[index] = candidate;
      }));
      const consolidated = categories.filter((candidate) => !matchingCategories.includes(candidate) || candidate === category);
      categories.splice(0, categories.length, ...consolidated);
    } else { category = { name: cleanMarkName(config.category), items: [] }; categories.push(category); }
    const marks = { name: cleanMarkName(config.assessment), obtained: result.obtained, total: result.total, review_required: reviewCount > 0, review_count: reviewCount, feedback: result.feedback, repository: result.repository, graded_at: result.graded_at };
    const existing = category.items.find((item) => markNameKey(item.name) === markNameKey(config.assessment));
    if (existing) Object.assign(existing, marks); else category.items.push(marks);
    const hiddenCategoryKeys = new Set((Array.isArray(courseSnapshot?.data()?.hidden_mark_categories) ? courseSnapshot.data().hidden_mark_categories : []).map(markNameKey).filter(Boolean));
    categoryHiddenFromStudents = hiddenCategoryKeys.has(categoryKey);
    const publicCategories = categories.filter((candidate) => !hiddenCategoryKeys.has(markNameKey(candidate?.name)));
    const updatedAt = FieldValue.serverTimestamp();
    transaction.set(privateRef, { enrollment_id: ref.id, user_id: enrollment.user_id, course_id: enrollment.course_id, marks: { categories }, updated_at: updatedAt });
    transaction.update(ref, { marks: { categories: publicCategories }, updated_at: updatedAt });
  });
  const [privateVerification, publicVerification] = await Promise.all([privateRef.get(), ref.get()]); const savedCategories = Array.isArray(privateVerification.data()?.marks?.categories) ? privateVerification.data().marks.categories : [];
  const savedCategory = savedCategories.find((candidate) => markNameKey(candidate?.name) === markNameKey(config.category));
  const savedMark = (Array.isArray(savedCategory?.items) ? savedCategory.items : []).find((item) => markNameKey(item?.name) === markNameKey(config.assessment));
  if (!savedMark || Number(savedMark.obtained) !== result.obtained || Number(savedMark.total) !== result.total) throw new Error(`Firestore read-back verification failed for ${student.registration_number}.`);
  const publicCategories = Array.isArray(publicVerification.data()?.marks?.categories) ? publicVerification.data().marks.categories : [];
  const publicCategory = publicCategories.find((candidate) => markNameKey(candidate?.name) === markNameKey(config.category));
  const publicMark = (Array.isArray(publicCategory?.items) ? publicCategory.items : []).find((item) => markNameKey(item?.name) === markNameKey(config.assessment));
  if (categoryHiddenFromStudents ? Boolean(publicCategory) : (!publicMark || Number(publicMark.obtained) !== result.obtained || Number(publicMark.total) !== result.total)) throw new Error(`Student-visibility verification failed for ${student.registration_number}.`);
  console.log(`Updated and verified ${student.registration_number}: ${config.category}/${config.assessment} = ${result.obtained}/${result.total} (${categoryHiddenFromStudents ? "administrator-only" : "student-visible"})`);
  updated++;
}

console.log(`Firestore update complete: ${updated} updated, ${skipped} skipped because grading did not complete.`);
