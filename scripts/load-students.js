import fs from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";

const projectId = String(process.env.FIREBASE_PROJECT_ID || "").trim();
const requestedCourseId = String(process.env.COURSE_ID || "").trim();
const requestedSection = String(process.env.SECTION || "Both").trim();

if (!projectId) {
  throw new Error(
    "FIREBASE_PROJECT_ID is missing. Add it under GitHub repository variables."
  );
}

if (!requestedCourseId) {
  throw new Error("COURSE_ID is missing.");
}

const normalizedSection = requestedSection.toUpperCase();

if (!["A", "B", "BOTH"].includes(normalizedSection)) {
  throw new Error('SECTION must be "A", "B", or "Both".');
}

initializeApp({
  credential: applicationDefault(),
  projectId
});

const db = getFirestore();

function firstAvailable(object, fields, defaultValue = "") {
  for (const field of fields) {
    const value = object?.[field];

    if (value !== undefined && value !== null && value !== "") {
      return value;
    }
  }

  return defaultValue;
}

function normalizeText(value) {
  return String(value ?? "").trim();
}

function normalizeCourseId(enrollment) {
  return normalizeText(
    firstAvailable(enrollment, [
      "course_id",
      "courseId",
      "course_code",
      "courseCode"
    ])
  ).toUpperCase();
}

function normalizeEnrollmentSection(enrollment) {
  return normalizeText(
    firstAvailable(enrollment, ["section", "course_section", "courseSection"])
  ).toUpperCase();
}

function isApproved(enrollment) {
  const value = firstAvailable(enrollment, [
    "approved",
    "is_approved",
    "isApproved",
    "status"
  ]);

  if (typeof value === "boolean") {
    return value;
  }

  const normalized = normalizeText(value).toLowerCase();

  return ["approved", "true", "yes", "active"].includes(normalized);
}

function getUid(enrollmentDocument, enrollment) {
  const storedUid = normalizeText(
    firstAvailable(enrollment, [
      "firebase_uid",
      "firebaseUid",
      "user_id",
      "userId",
      "uid"
    ])
  );

  if (storedUid) {
    return storedUid;
  }

  /*
   * Supports this Firestore structure:
   *
   * users/{firebaseUid}/enrollments/{enrollmentId}
   */
  const parentDocument = enrollmentDocument.ref.parent.parent;

  if (parentDocument?.parent?.id === "users") {
    return parentDocument.id;
  }

  return "";
}

function validGitHubUsername(username) {
  /*
   * GitHub usernames:
   * - contain letters, numbers, and hyphens
   * - cannot start or end with a hyphen
   * - maximum length is 39 characters
   */
  return /^(?!-)(?!.*--)[A-Za-z0-9-]{1,39}(?<!-)$/.test(username);
}

async function findApprovedEnrollments() {
  /*
   * collectionGroup allows both of these designs:
   *
   * users/{uid}/enrollments/{enrollmentId}
   *
   * courses/{courseId}/enrollments/{enrollmentId}
   */
  const snapshot = await db.collectionGroup("enrollments").get();
  const selected = [];

  for (const enrollmentDocument of snapshot.docs) {
    const enrollment = enrollmentDocument.data();
    const courseId = normalizeCourseId(enrollment);
    const section = normalizeEnrollmentSection(enrollment);

    if (courseId !== requestedCourseId.toUpperCase()) {
      continue;
    }

    if (
      normalizedSection !== "BOTH" &&
      section !== normalizedSection
    ) {
      continue;
    }

    if (!isApproved(enrollment)) {
      continue;
    }

    const firebaseUid = getUid(enrollmentDocument, enrollment);

    if (!firebaseUid) {
      console.warn(
        `Skipping enrollment ${enrollmentDocument.ref.path}: Firebase UID is missing.`
      );
      continue;
    }

    selected.push({
      firebaseUid,
      enrollment,
      enrollmentPath: enrollmentDocument.ref.path
    });
  }

  return selected;
}

async function loadStudentProfile(firebaseUid) {
  const snapshot = await db.collection("users").doc(firebaseUid).get();

  if (!snapshot.exists) {
    return null;
  }

  return snapshot.data();
}

async function buildStudents(enrollments) {
  const students = [];
  const seenUsers = new Set();

  for (const selectedEnrollment of enrollments) {
    const { firebaseUid, enrollment, enrollmentPath } = selectedEnrollment;

    /*
     * Prevent the same student from being graded twice if duplicate
     * enrollment records exist.
     */
    if (seenUsers.has(firebaseUid)) {
      console.warn(
        `Ignoring duplicate enrollment for Firebase UID ${firebaseUid}.`
      );
      continue;
    }

    const profile = await loadStudentProfile(firebaseUid);

    if (!profile) {
      console.warn(
        `Skipping ${firebaseUid}: users/${firebaseUid} does not exist.`
      );
      continue;
    }

    const githubUsername = normalizeText(
      firstAvailable(profile, [
        "user_name",
        "github_username",
        "githubUsername"
      ])
    );

    if (!githubUsername) {
      console.warn(
        `Skipping ${firebaseUid}: GitHub username is missing from the user profile.`
      );
      continue;
    }

    if (!validGitHubUsername(githubUsername)) {
      console.warn(
        `Skipping ${firebaseUid}: "${githubUsername}" is not a valid GitHub username.`
      );
      continue;
    }

    const registrationNumber = normalizeText(
      firstAvailable(profile, [
        "registration_number",
        "registrationNumber"
      ])
    );

    const firstName = normalizeText(
      firstAvailable(profile, ["first_name", "firstName"])
    );

    const lastName = normalizeText(
      firstAvailable(profile, ["last_name", "lastName"])
    );

    students.push({
      firebase_uid: firebaseUid,
      github_username: githubUsername,
      registration_number: registrationNumber,
      first_name: firstName,
      last_name: lastName,
      email: normalizeText(profile.email),
      photo_url: normalizeText(
        firstAvailable(profile, ["photo_url", "photoURL"])
      ),
      github_id: normalizeText(
        firstAvailable(profile, ["github_id", "githubId"])
      ),
      course_id: normalizeText(
        firstAvailable(enrollment, [
          "course_id",
          "courseId",
          "course_code",
          "courseCode"
        ])
      ),
      course_name: normalizeText(
        firstAvailable(enrollment, ["course_name", "courseName"])
      ),
      section: normalizeEnrollmentSection(enrollment),
      enrollment_id: path.basename(enrollmentPath),
      enrollment_path: enrollmentPath
    });

    seenUsers.add(firebaseUid);
  }

  return students;
}

async function main() {
  console.log(`Firebase project: ${projectId}`);
  console.log(`Course: ${requestedCourseId}`);
  console.log(`Section: ${requestedSection}`);
  console.log("Loading approved enrollments from Firestore...");

  const enrollments = await findApprovedEnrollments();
  const students = await buildStudents(enrollments);

  students.sort((left, right) => {
    const registrationComparison =
      left.registration_number.localeCompare(right.registration_number);

    if (registrationComparison !== 0) {
      return registrationComparison;
    }

    return left.github_username.localeCompare(right.github_username);
  });

  await fs.mkdir("results", { recursive: true });
  await fs.writeFile(
    "results/students.json",
    `${JSON.stringify(students, null, 2)}\n`,
    "utf8"
  );

  console.log(`Approved enrollment records found: ${enrollments.length}`);
  console.log(`Valid students selected: ${students.length}`);
  console.log("Student list saved to results/students.json");

  for (const student of students) {
    console.log(
      [
        student.registration_number || "No registration number",
        student.github_username,
        student.course_id,
        `Section ${student.section}`
      ].join(" | ")
    );
  }

  if (students.length === 0) {
    throw new Error(
      `No approved students were found for course "${requestedCourseId}" ` +
      `and section "${requestedSection}".`
    );
  }
}

main().catch((error) => {
  console.error(`Failed to load students: ${error.message}`);
  process.exitCode = 1;
});