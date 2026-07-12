import fs from "node:fs/promises";
import path from "node:path";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const projectId = String(process.env.FIREBASE_PROJECT_ID || "").trim();
const courseInput = String(process.env.COURSE_ID || "").trim().toUpperCase();
const sectionInput = String(process.env.SECTION || "Both").trim().toUpperCase();
const selection = String(process.env.STUDENT_SELECTION || "All").trim().toLowerCase();
const requestedRegistrations = new Set(String(process.env.REGISTRATION_NUMBERS || "").split(/[,;\n]+/).map((v) => v.trim().toUpperCase()).filter(Boolean));

if (!projectId || !courseInput) throw new Error("FIREBASE_PROJECT_ID and COURSE_ID are required.");
if (!["A", "B", "BOTH"].includes(sectionInput)) throw new Error("SECTION must be A, B, or Both.");
if (!["all", "registration numbers"].includes(selection)) throw new Error("Invalid STUDENT_SELECTION.");
if (selection === "registration numbers" && !requestedRegistrations.size) throw new Error("Enter at least one registration number.");

initializeApp({ credential: applicationDefault(), projectId });
const db = getFirestore();
const enrollmentSnapshot = await db.collection("enrollments").get();
const selected = [];

for (const enrollmentDoc of enrollmentSnapshot.docs) {
  const enrollment = enrollmentDoc.data();
  const courseValues = [enrollment.course_id, enrollment.course_code].map((v) => String(v || "").trim().toUpperCase());
  if (!enrollment.approved || !courseValues.includes(courseInput)) continue;
  const section = String(enrollment.section || "").trim().toUpperCase();
  if (sectionInput !== "BOTH" && section !== sectionInput) continue;
  const userId = String(enrollment.user_id || "").trim();
  const userDoc = await db.collection("users").doc(userId).get();
  if (!userDoc.exists) { console.warn(`Skipping missing user ${userId}.`); continue; }
  const profile = userDoc.data();
  const registration = String(profile.registration_number || "").trim().toUpperCase();
  if (selection === "registration numbers" && !requestedRegistrations.has(registration)) continue;
  const username = String(profile.user_name || "").trim();
  if (!/^(?!-)(?!.*--)[A-Za-z0-9-]{1,39}(?<!-)$/.test(username)) { console.warn(`Skipping invalid GitHub username for ${registration}.`); continue; }
  selected.push({
    firebase_uid: userId,
    enrollment_path: enrollmentDoc.ref.path,
    enrollment_id: enrollmentDoc.id,
    github_username: username,
    registration_number: registration,
    first_name: String(profile.first_name || ""),
    last_name: String(profile.last_name || ""),
    email: String(profile.email || ""),
    github_id: String(profile.github_id || ""),
    photo_url: String(profile.photo_url || ""),
    course_id: String(enrollment.course_id || ""),
    course_code: String(enrollment.course_code || ""),
    course_name: String(enrollment.course_name || ""),
    section
  });
}

selected.sort((a, b) => a.registration_number.localeCompare(b.registration_number));
if (selection === "registration numbers") {
  const found = new Set(selected.map((student) => student.registration_number));
  const missing = [...requestedRegistrations].filter((number) => !found.has(number));
  if (missing.length) throw new Error(`No approved matching enrollment for: ${missing.join(", ")}`);
}
if (!selected.length) throw new Error("No approved students matched the selected course, section, and registration filter.");
await fs.mkdir(path.resolve("results"), { recursive: true });
await fs.writeFile(path.resolve("results/students.json"), `${JSON.stringify(selected, null, 2)}\n`);
console.log(`Students selected: ${selected.length}`);
selected.forEach((s) => console.log(`${s.registration_number} | ${s.github_username} | ${s.course_code} | Section ${s.section}`));

